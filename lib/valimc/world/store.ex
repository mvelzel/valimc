defmodule Valimc.World.Store do
  use GenServer, restart: :temporary
  alias Valimc.World.{ItemRecords, Items}

  @moduledoc "Independently supervised resource I/O with one monitored owner and fenced writes."
  def start_link({key, owner}),
    do:
      GenServer.start_link(__MODULE__, {key, owner},
        name: {:via, Registry, {Valimc.RegionStoreRegistry, key}}
      )

  def open(key), do: open(key, 100)
  defp open(_key, 0), do: {:error, :store_restarting}

  defp open(key, attempts) do
    result =
      DynamicSupervisor.start_child(Valimc.RegionStoreSupervisor, {__MODULE__, {key, self()}})

    case result do
      {:ok, pid} -> claim(pid, key, attempts)
      {:error, {:already_started, pid}} -> claim(pid, key, attempts)
      error -> error
    end
  end

  defp claim(pid, key, attempts) do
    case GenServer.call(pid, :claim) do
      {:ok, lease} -> {:ok, pid, lease}
      error -> error
    end
  catch
    :exit, reason ->
      if Process.alive?(pid) do
        exit(reason)
      else
        Process.sleep(1)
        open(key, attempts - 1)
      end
  end

  def load(pid), do: GenServer.call(pid, :load)

  def snapshot(pid, lease, edits, {owner, epoch}, revision),
    do: GenServer.cast(pid, {:snapshot, lease, edits, {owner, epoch}, revision})

  def flush(pid, lease, edits), do: GenServer.call(pid, {:flush, lease, edits}, 15_000)
  def close(pid, lease), do: GenServer.call(pid, {:close, lease}, 1000)
  def load_items(pid), do: GenServer.call(pid, :load_items)

  def commit_items(pid, lease, items, receipts, {owner, epoch}, token),
    do:
      GenServer.cast(pid, {:items, lease, Items.records(items), receipts, {owner, epoch}, token})

  def item_path(nil, _), do: nil
  def item_path(base, {rx, rz}), do: Path.join(base, "r.#{rx}.#{rz}.items")
  @impl true
  def init({{rx, rz} = key, owner}) do
    path =
      case Valimc.config(:world_path) do
        nil -> nil
        base -> Path.join(base, "r.#{rx}.#{rz}.etf")
      end

    {:ok,
     %{
       blocks: path,
       items: item_path(Valimc.config(:world_path), key),
       key: key,
       owner: owner,
       monitor: Process.monitor(owner),
       lease: make_ref()
     }}
  end

  @impl true
  def handle_call(:claim, {owner, _}, %{owner: owner} = state),
    do: {:reply, {:ok, state.lease}, state}

  def handle_call(:claim, {owner, _}, state) do
    if Process.alive?(state.owner) do
      {:reply, {:error, :store_owned}, state}
    else
      Process.demonitor(state.monitor, [:flush])
      next = %{state | owner: owner, monitor: Process.monitor(owner), lease: make_ref()}
      {:reply, {:ok, next.lease}, next}
    end
  end

  def handle_call(:load, _from, %{blocks: path} = state) do
    edits =
      case path && File.read(path, [:raw]) do
        {:ok, data} ->
          {:valimc_region, 1, edits} = :erlang.binary_to_term(data, [:safe])
          true = is_map(edits)
          edits

        {:error, :enoent} ->
          %{}

        nil ->
          %{}

        {:error, reason} ->
          raise File.Error, reason: reason, action: "read region", path: path
      end

    {:reply, edits, state}
  end

  def handle_call({:flush, lease, edits}, _from, %{lease: lease} = state),
    do: {:reply, write(state.blocks, edits), state}

  def handle_call({:flush, _, _}, _from, state), do: {:reply, {:error, :stale_store_lease}, state}

  def handle_call({:close, lease}, _from, %{lease: lease} = state),
    do: {:stop, :normal, :ok, state}

  def handle_call({:close, _}, _from, state), do: {:reply, {:error, :stale_store_lease}, state}

  def handle_call(:load_items, _from, state) do
    result =
      with {:ok, data} <- read_items(state.items, state.key),
           do: {:ok, Map.put(data, :persistent, state.items != nil)}

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:snapshot, lease, edits, {owner, epoch}, revision}, %{lease: lease} = state) do
    result = write(state.blocks, edits)

    case result do
      :ok ->
        :ok

      {:error, reason} ->
        require Logger
        Logger.error("Region save failed: #{inspect(reason)}")
    end

    send(owner, {:resource, epoch, {:saved, self(), revision, result}})
    {:noreply, state}
  end

  def handle_cast(
        {:items, lease, records, receipts, {owner, epoch}, token},
        %{lease: lease} = state
      ) do
    result =
      with {:ok, bytes} <- ItemRecords.encode(state.key, records, receipts),
           do: write_items(state.items, bytes)

    send(owner, {:resource, epoch, {:items_saved, self(), token, result}})
    {:noreply, state}
  end

  def handle_cast({:snapshot, _, _, {owner, epoch}, revision}, state) do
    send(owner, {:resource, epoch, {:saved, self(), revision, {:error, :stale_store_lease}}})
    {:noreply, state}
  end

  def handle_cast({:items, _, _, _, {owner, epoch}, token}, state) do
    send(owner, {:resource, epoch, {:items_saved, self(), token, {:error, :stale_store_lease}}})
    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _},
        %{monitor: monitor, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  defp read_items(nil, _key), do: {:ok, %{records: [], receipts: %{}}}

  defp read_items(path, key) do
    case File.open(path, [:read, :raw, :binary], fn io ->
           :file.read(io, ItemRecords.max_bytes() + 1)
         end) do
      {:ok, {:ok, bytes}} -> ItemRecords.decode(bytes, key)
      {:error, :enoent} -> {:ok, %{records: [], receipts: %{}}}
      {:ok, :eof} -> {:error, :invalid_item_file}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp write_items(nil, _bytes), do: :ok

  defp write_items(path, bytes) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path <> ".tmp", bytes, [:binary, :sync]),
         :ok <- File.rename(path <> ".tmp", path),
         do: :ok
  end

  defp write(nil, _), do: :ok

  defp write(path, edits) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <-
           File.write(
             path <> ".tmp",
             :erlang.term_to_binary({:valimc_region, 1, edits}, [:compressed]),
             [:binary, :sync]
           ),
         :ok <- File.rename(path <> ".tmp", path) do
      Valimc.Metrics.add(:region_saves)
      :ok
    end
  end
end
