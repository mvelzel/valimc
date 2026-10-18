defmodule Valimc.World.Store do
  use GenServer, restart: :temporary
  alias Valimc.World.{Chunk, Containers, ItemLedger, Items, MiningRecord}

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
  def load_containers(pid), do: GenServer.call(pid, :load_containers)

  def flush_containers(pid, lease, containers),
    do: GenServer.call(pid, {:flush_containers, lease, containers}, 15_000)

  def commit_containers(pid, lease, containers, {owner, epoch}, token),
    do: GenServer.cast(pid, {:containers, lease, containers, {owner, epoch}, token})

  def flush_items(pid, lease, items, receipts),
    do: GenServer.call(pid, {:flush_items, lease, Items.snapshot(items), receipts}, 15_000)

  def commit_items(pid, lease, items, receipts, {owner, epoch}, token),
    do:
      GenServer.cast(pid, {:items, lease, Items.snapshot(items), receipts, {owner, epoch}, token})

  def commit_mining(pid, lease, %{items: items} = proposal, owner, token) do
    proposal = proposal |> Map.delete(:items) |> Map.merge(Items.snapshot(items))
    GenServer.cast(pid, {:mining, lease, proposal, owner, token})
  end

  def item_path(nil, _), do: nil
  def item_path(base, {rx, rz}), do: Path.join(base, "r.#{rx}.#{rz}.items")
  def mining_path(nil, _), do: nil
  def mining_path(base, {rx, rz}), do: Path.join(base, "r.#{rx}.#{rz}.mining")
  def container_path(nil, _), do: nil
  def container_path(base, {rx, rz}), do: Path.join(base, "r.#{rx}.#{rz}.containers")
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
       mining: mining_path(Valimc.config(:world_path), key),
       containers: container_path(Valimc.config(:world_path), key),
       recovered: false,
       key: key,
       owner: owner,
       monitor: Process.monitor(owner),
       lease: make_ref()
     }}
  end

  @impl true
  def handle_call(:claim, {owner, _}, %{owner: owner} = state), do: claim_ready(state)

  def handle_call(:claim, {owner, _}, state) do
    if Process.alive?(state.owner) do
      {:reply, {:error, :store_owned}, state}
    else
      Process.demonitor(state.monitor, [:flush])
      next = %{state | owner: owner, monitor: Process.monitor(owner), lease: make_ref()}
      claim_ready(next)
    end
  end

  def handle_call(:load, _from, %{blocks: path} = state),
    do: {:reply, read_blocks(path), state}

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

  def handle_call(:load_containers, _from, state),
    do: {:reply, read_containers(state.containers, state.key), state}

  def handle_call({:flush_containers, lease, containers}, _from, %{lease: lease} = state),
    do: {:reply, save_containers(state, containers), state}

  def handle_call({:flush_containers, _, _}, _from, state),
    do: {:reply, {:error, :stale_store_lease}, state}

  def handle_call({:flush_items, lease, records, receipts}, _from, %{lease: lease} = state),
    do: {:reply, save_items(state, records, receipts), state}

  def handle_call({:flush_items, _, _, _}, _from, state),
    do: {:reply, {:error, :stale_store_lease}, state}

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
    result = save_items(state, records, receipts)
    send(owner, {:resource, epoch, {:items_saved, self(), token, result}})
    {:noreply, state}
  end

  def handle_cast({:mining, lease, proposal, {owner, epoch}, token}, %{lease: lease} = state) do
    case mining_proposal(state.key, proposal) do
      {:ok, journal, item_bytes, container_bytes} ->
        result =
          with :ok <- write_atomic(state.mining, journal),
               :ok <- write(state.blocks, proposal.edits),
               :ok <- write_atomic(state.items, item_bytes),
               :ok <- write_containers(state.containers, container_bytes),
               do: remove_mining(state.mining)

        send(owner, {:resource, epoch, {:mining_saved, self(), token, result}})

        case result do
          :ok -> {:noreply, state}
          {:error, reason} -> {:stop, {:mining_storage_failed, reason}, state}
        end

      {:error, _} = error ->
        send(owner, {:resource, epoch, {:mining_saved, self(), token, error}})
        {:noreply, state}
    end
  end

  def handle_cast(
        {:containers, lease, containers, {owner, epoch}, token},
        %{lease: lease} = state
      ) do
    result = save_containers(state, containers)
    send(owner, {:resource, epoch, {:containers_saved, self(), token, result}})
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

  def handle_cast({:mining, _, _, {owner, epoch}, token}, state) do
    send(owner, {:resource, epoch, {:mining_saved, self(), token, {:error, :stale_store_lease}}})
    {:noreply, state}
  end

  def handle_cast({:containers, _, _, {owner, epoch}, token}, state) do
    send(
      owner,
      {:resource, epoch, {:containers_saved, self(), token, {:error, :stale_store_lease}}}
    )

    {:noreply, state}
  end

  @impl true
  def handle_info(
        {:DOWN, monitor, :process, owner, _},
        %{monitor: monitor, owner: owner} = state
      ),
      do: {:stop, :normal, state}

  def handle_info(_, state), do: {:noreply, state}

  defp save_items(state, %{records: records, ledger: ledger}, receipts) do
    with {:ok, bytes} <- ItemLedger.encode(state.key, records, receipts, ledger),
         do: write_items(state.items, bytes)
  end

  defp save_containers(state, containers) do
    with {:ok, bytes} <- Containers.encode(state.key, containers),
         do: write_atomic(state.containers, bytes)
  end

  defp read_containers(nil, _), do: {:ok, %Containers{}}

  defp read_containers(path, key) do
    case File.open(path, [:read, :raw, :binary], &:file.read(&1, Containers.max_bytes() + 1)) do
      {:ok, {:ok, bytes}} -> Containers.decode(bytes, key)
      {:error, :enoent} -> {:ok, %Containers{}}
      {:ok, :eof} -> {:error, :invalid_container_snapshot}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_items(nil, _key), do: {:ok, %{records: [], receipts: %{}, ledger: %ItemLedger{}}}

  defp read_items(path, key) do
    case File.open(path, [:read, :raw, :binary], fn io ->
           :file.read(io, ItemLedger.max_bytes() + 1)
         end) do
      {:ok, {:ok, bytes}} ->
        case ItemLedger.decode(bytes, key) do
          {:ok, data} -> {:ok, data}
          {:error, _} -> {:error, :invalid_item_file}
        end

      {:error, :enoent} ->
        read_items(nil, key)

      {:ok, :eof} ->
        {:error, :invalid_item_file}

      {:ok, {:error, reason}} ->
        {:error, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp claim_ready(state) do
    case recover_mining(state) do
      :ok ->
        {:reply, {:ok, state.lease}, %{state | recovered: true}}

      {:error, reason} ->
        {:stop, {:mining_recovery_failed, reason}, {:error, {:mining_recovery_failed, reason}},
         state}
    end
  end

  defp mining_proposal(
         key,
         %{
           edits: edits,
           changes: changes,
           records: records,
           receipts: receipts,
           ledger: ledger
         } = proposal
       )
       when is_map(edits) and map_size(edits) <= 131_072 and is_map(changes) do
    with {:ok, item_bytes} <- ItemLedger.encode(key, records, receipts, ledger),
         {:ok, container_bytes} <- proposal_containers(key, proposal),
         {:ok, journal} <- proposal_journal(key, changes, item_bytes, container_bytes),
         true <- Enum.all?(changes, fn {pos, block} -> Chunk.block_at(edits, pos) == block end) do
      {:ok, journal, item_bytes, container_bytes}
    else
      _ -> {:error, :invalid_mining_proposal}
    end
  end

  defp mining_proposal(_, _), do: {:error, :invalid_mining_proposal}

  defp proposal_containers(key, %{containers: containers}), do: Containers.encode(key, containers)
  defp proposal_containers(_, _), do: {:ok, nil}

  defp proposal_journal(key, changes, items, nil), do: MiningRecord.encode(key, changes, items)

  defp proposal_journal(key, changes, items, containers),
    do: MiningRecord.encode(key, changes, items, containers)

  defp write_containers(_, nil), do: :ok
  defp write_containers(path, bytes), do: write_atomic(path, bytes)

  defp recover_mining(%{recovered: true}), do: :ok
  defp recover_mining(%{mining: nil}), do: :ok

  defp recover_mining(state) do
    case read_mining(state.mining, state.key) do
      {:ok, nil} ->
        :ok

      {:ok, proposal} ->
        edits =
          Enum.reduce(proposal.edits, read_blocks(state.blocks), fn {{_, y, _} = pos, block},
                                                                    acc ->
            if block == Chunk.base(y), do: Map.delete(acc, pos), else: Map.put(acc, pos, block)
          end)

        with true <- map_size(edits) <= 131_072,
             :ok <- write(state.blocks, edits),
             :ok <- write_atomic(state.items, proposal.item_bytes),
             :ok <- write_containers(state.containers, Map.get(proposal, :container_bytes)) do
          remove_mining(state.mining)
        else
          false -> {:error, :region_edit_limit}
          error -> error
        end

      error ->
        error
    end
  rescue
    error in [File.Error, MatchError, ArgumentError] ->
      {:error, {:invalid_region_file, Exception.message(error)}}
  end

  defp read_mining(path, key) do
    case File.open(path, [:read, :raw, :binary], &:file.read(&1, MiningRecord.max_bytes() + 1)) do
      {:ok, {:ok, bytes}} -> MiningRecord.decode(bytes, key)
      {:error, :enoent} -> {:ok, nil}
      {:ok, :eof} -> {:error, :invalid_mining_record}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_blocks(path) do
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
  end

  defp remove_mining(nil), do: :ok

  defp remove_mining(path) do
    case File.rm(path) do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  defp write_items(path, bytes) do
    result = write_atomic(path, bytes)
    if result == :ok and path != nil, do: Valimc.Metrics.add(:item_snapshot_saves)
    result
  end

  defp write_atomic(nil, _bytes), do: :ok

  defp write_atomic(path, bytes) do
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
