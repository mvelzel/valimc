defmodule Valimc.World.Store do
  use GenServer
  alias Valimc.World.{ItemRecords, Items}

  @moduledoc "A per-region file writer; disk I/O never runs in a player or ticking region process."
  def start_link(key), do: GenServer.start_link(__MODULE__, key)
  def load(pid), do: GenServer.call(pid, :load)

  def snapshot(pid, edits, {owner, epoch}, revision),
    do: GenServer.cast(pid, {:snapshot, edits, {owner, epoch}, revision})

  def flush(pid, edits), do: GenServer.call(pid, {:flush, edits}, 15_000)
  def load_items(pid), do: GenServer.call(pid, :load_items)

  def commit_items(pid, items, receipts, {owner, epoch}, token),
    do: GenServer.cast(pid, {:items, Items.records(items), receipts, {owner, epoch}, token})

  def item_path(nil, _), do: nil
  def item_path(base, {rx, rz}), do: Path.join(base, "r.#{rx}.#{rz}.items")
  @impl true
  def init({rx, rz}) do
    path =
      case Valimc.config(:world_path) do
        nil -> nil
        base -> Path.join(base, "r.#{rx}.#{rz}.etf")
      end

    {:ok, %{blocks: path, items: item_path(Valimc.config(:world_path), {rx, rz}), key: {rx, rz}}}
  end

  @impl true
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

  def handle_call({:flush, edits}, _from, state), do: {:reply, write(state.blocks, edits), state}

  def handle_call(:load_items, _from, state) do
    result =
      with {:ok, data} <- read_items(state.items, state.key),
           do: {:ok, Map.put(data, :persistent, state.items != nil)}

    {:reply, result, state}
  end

  @impl true
  def handle_cast({:snapshot, edits, {owner, epoch}, revision}, state) do
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

  def handle_cast({:items, records, receipts, {owner, epoch}, token}, state) do
    result =
      with {:ok, bytes} <- ItemRecords.encode(state.key, records, receipts),
           do: write_items(state.items, bytes)

    send(owner, {:resource, epoch, {:items_saved, self(), token, result}})
    {:noreply, state}
  end

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
