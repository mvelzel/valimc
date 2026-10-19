defmodule Valimc.World.Store do
  use GenServer, restart: :temporary
  alias Valimc.World.{Chunk, Containers, ItemLedger, Items, MiningRecord, RegionLog}

  @moduledoc """
  Independently supervised resource I/O with one monitored owner and fenced writes.

  Durable state lives in a `RegionLog` directory (`r.X.Z/`). Every write is one
  frame: block changes as `{:cells, %{position => block}}` and full values for
  `{:items, bytes}` and `{:containers, bytes}`, so a mining commit changing all
  three is atomic with one fsync. Checkpoints hold the sparse block image.
  The log is checkpointed once appended frames exceed `@checkpoint_bytes`. Legacy
  per-file snapshots (`r.X.Z.etf/.items/.containers/.mining`) are imported once.
  """
  @checkpoint_bytes 32 * 1024 * 1024
  @empty %{blocks: %{}, items: nil, containers: nil}
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

  @doc "Persist block `cells` (`position => block`) asynchronously; acknowledged with `:saved`."
  def snapshot(pid, lease, cells, {owner, epoch}, revision),
    do: GenServer.cast(pid, {:snapshot, lease, cells, {owner, epoch}, revision})

  def flush(pid, lease, cells), do: GenServer.call(pid, {:flush, lease, cells}, 15_000)
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
  def block_path(nil, _), do: nil
  def block_path(base, {rx, rz}), do: Path.join(base, "r.#{rx}.#{rz}.etf")
  def log_dir(nil, _), do: nil
  def log_dir(base, {rx, rz}), do: Path.join(base, "r.#{rx}.#{rz}")

  @doc """
  The durable value of `part` (`:blocks` edit map, `:items` or `:containers` bytes)
  as recovery would see it, without opening the log for writing. For tests/tools.
  """
  def durable(base, key, part) when part in [:blocks, :items, :containers] do
    dir = log_dir(base, key)

    values =
      if File.dir?(dir, [:raw]) do
        {:ok, recovered} = RegionLog.read(dir)
        fold(recovered)
      else
        {:ok, values} = import_v1(base, key)
        values
      end

    Map.fetch!(values, part)
  end

  @impl true
  def init({key, owner}) do
    {:ok,
     %{
       base: Valimc.config(:world_path),
       key: key,
       log: nil,
       values: @empty,
       appended: 0,
       recovered: false,
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

  def handle_call(:load, _from, state), do: {:reply, state.values.blocks, state}

  def handle_call({:flush, lease, cells}, _from, %{lease: lease} = state) do
    {result, state} = write(state, cells_parts(cells))
    {:reply, result, state}
  end

  def handle_call({:flush, _, _}, _from, state), do: {:reply, {:error, :stale_store_lease}, state}

  def handle_call({:close, lease}, _from, %{lease: lease} = state) do
    RegionLog.close(state.log)
    {:stop, :normal, :ok, %{state | log: nil}}
  end

  def handle_call({:close, _}, _from, state), do: {:reply, {:error, :stale_store_lease}, state}

  def handle_call(:load_items, _from, state) do
    result =
      with {:ok, data} <- read_items(state.values.items, state.key),
           do: {:ok, Map.put(data, :persistent, state.base != nil)}

    {:reply, result, state}
  end

  def handle_call(:load_containers, _from, state),
    do: {:reply, read_containers(state.values.containers, state.key), state}

  def handle_call({:flush_containers, lease, containers}, _from, %{lease: lease} = state) do
    {result, state} = save_containers(state, containers)
    {:reply, result, state}
  end

  def handle_call({:flush_containers, _, _}, _from, state),
    do: {:reply, {:error, :stale_store_lease}, state}

  def handle_call({:flush_items, lease, records, receipts}, _from, %{lease: lease} = state) do
    {result, state} = save_items(state, records, receipts)
    {:reply, result, state}
  end

  def handle_call({:flush_items, _, _, _}, _from, state),
    do: {:reply, {:error, :stale_store_lease}, state}

  @impl true
  def handle_cast({:snapshot, lease, cells, {owner, epoch}, revision}, %{lease: lease} = state) do
    {result, state} = write(state, cells_parts(cells))

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
    {result, state} = save_items(state, records, receipts)
    send(owner, {:resource, epoch, {:items_saved, self(), token, result}})
    {:noreply, state}
  end

  def handle_cast({:mining, lease, proposal, {owner, epoch}, token}, %{lease: lease} = state) do
    case mining_proposal(state.key, proposal) do
      {:ok, _journal, item_bytes, container_bytes} ->
        # One frame: blocks, items and containers commit together.
        parts = [{:cells, proposal.changes}, {:items, item_bytes}]
        parts = if container_bytes, do: parts ++ [{:containers, container_bytes}], else: parts
        {result, state} = write(state, parts)
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
    {result, state} = save_containers(state, containers)
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
    case ItemLedger.encode(state.key, records, receipts, ledger) do
      {:ok, bytes} -> write(state, [{:items, bytes}])
      error -> {error, state}
    end
  end

  defp save_containers(state, containers) do
    case Containers.encode(state.key, containers) do
      {:ok, bytes} -> write(state, [{:containers, bytes}])
      error -> {error, state}
    end
  end

  defp read_containers(nil, _), do: {:ok, %Containers{}}
  defp read_containers(bytes, key), do: Containers.decode(bytes, key)

  defp read_items(nil, _key), do: {:ok, %{records: [], receipts: %{}, ledger: %ItemLedger{}}}

  defp read_items(bytes, key) do
    case ItemLedger.decode(bytes, key) do
      {:ok, data} -> {:ok, data}
      {:error, _} -> {:error, :invalid_item_file}
    end
  end

  defp claim_ready(%{recovered: true} = state), do: {:reply, {:ok, state.lease}, state}

  defp claim_ready(state) do
    case recover(state) do
      {:ok, state} ->
        {:reply, {:ok, state.lease}, %{state | recovered: true}}

      {:error, reason} ->
        {:stop, {:mining_recovery_failed, reason}, {:error, {:mining_recovery_failed, reason}},
         state}
    end
  end

  # Open the region log (importing legacy files once) and fold it into values.
  defp recover(%{base: nil} = state), do: {:ok, state}

  defp recover(state) do
    dir = log_dir(state.base, state.key)

    if File.dir?(dir, [:raw]) do
      with {:ok, log, recovered} <- RegionLog.open(dir),
           do: {:ok, %{state | log: log, values: fold(recovered)}}
    else
      with {:ok, values} <- import_v1(state.base, state.key),
           {:ok, log, _} <- RegionLog.open(dir),
           {:ok, log} <- RegionLog.checkpoint(log, values) do
        retire_v1(state.base, state.key)
        {:ok, %{state | log: log, values: values}}
      end
    end
  rescue
    error in [File.Error, MatchError, ArgumentError] ->
      {:error, {:invalid_region_file, Exception.message(error)}}
  end

  defp fold(%{checkpoint: checkpoint, frames: frames}) do
    Enum.reduce(frames, checkpoint || @empty, fn %{ops: ops}, values ->
      Enum.reduce(ops, values, fn
        {:cells, cells}, acc -> %{acc | blocks: apply_cells(acc.blocks, cells)}
        {part, value}, acc when part in [:blocks, :items, :containers] -> %{acc | part => value}
        _, acc -> acc
      end)
    end)
  end

  # Legacy whole-file snapshots plus a pending mining journal, merged as the old
  # store recovered them.
  defp import_v1(base, key) do
    with {:ok, blocks} <- read_v1_blocks(block_path(base, key)),
         {:ok, items} <- read_v1(item_path(base, key), ItemLedger.max_bytes()),
         {:ok, containers} <- read_v1(container_path(base, key), Containers.max_bytes()),
         {:ok, journal} <- read_mining(mining_path(base, key), key) do
      values = %{blocks: blocks, items: items, containers: containers}

      case journal do
        nil ->
          {:ok, values}

        proposal ->
          edits =
            Enum.reduce(proposal.edits, blocks, fn {{_, y, _} = pos, block}, acc ->
              if block == Chunk.base(y), do: Map.delete(acc, pos), else: Map.put(acc, pos, block)
            end)

          if map_size(edits) <= 131_072,
            do:
              {:ok,
               %{
                 blocks: edits,
                 items: proposal.item_bytes,
                 containers: Map.get(proposal, :container_bytes) || containers
               }},
            else: {:error, :region_edit_limit}
      end
    end
  end

  defp retire_v1(base, key) do
    for path <- [block_path(base, key), item_path(base, key), container_path(base, key)],
        File.exists?(path),
        do: File.rename(path, path <> ".v1")

    File.rm(mining_path(base, key))
  end

  defp read_v1(path, limit) do
    case File.open(path, [:read, :raw, :binary], &:file.read(&1, limit + 1)) do
      {:ok, {:ok, bytes}} when byte_size(bytes) <= limit -> {:ok, bytes}
      {:ok, {:ok, _}} -> {:error, :oversized_region_file}
      {:error, :enoent} -> {:ok, nil}
      {:ok, :eof} -> {:error, :invalid_region_file}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
    end
  end

  # Raw reads keep a slow or blocked file off the global file server.
  defp read_v1_blocks(path) do
    case File.read(path, [:raw]) do
      {:ok, data} ->
        {:valimc_region, 1, edits} = :erlang.binary_to_term(data, [:safe])
        true = is_map(edits)
        {:ok, edits}

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
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

  defp mining_proposal(
         key,
         %{changes: changes, records: records, receipts: receipts, ledger: ledger} = proposal
       )
       when is_map(changes) do
    with {:ok, item_bytes} <- ItemLedger.encode(key, records, receipts, ledger),
         {:ok, container_bytes} <- proposal_containers(key, proposal),
         {:ok, journal} <- proposal_journal(key, changes, item_bytes, container_bytes) do
      {:ok, journal, item_bytes, container_bytes}
    else
      _ -> {:error, :invalid_mining_proposal}
    end
  end

  defp mining_proposal(_, _), do: {:error, :invalid_mining_proposal}

  defp proposal_containers(key, %{containers: containers}), do: Containers.encode(key, containers)
  defp proposal_containers(_, _), do: {:ok, nil}

  # The journal encoding still validates the proposal's change bounds.
  defp proposal_journal(key, changes, items, nil), do: MiningRecord.encode(key, changes, items)

  defp proposal_journal(key, changes, items, containers),
    do: MiningRecord.encode(key, changes, items, containers)

  # Append one frame of full values; without a world path, keep them in memory.
  defp write(state, []), do: {:ok, state}
  defp write(%{log: nil} = state, parts), do: {:ok, apply_parts(state, parts)}

  defp write(state, parts) do
    case RegionLog.append(state.log, [parts]) do
      {:ok, log, _lsn} ->
        bytes = :erlang.external_size(parts)

        for {part, _} <- parts do
          Valimc.Metrics.add(if part == :blocks, do: :region_saves, else: :item_snapshot_saves)
        end

        state = %{apply_parts(state, parts) | log: log, appended: state.appended + bytes}
        {:ok, maybe_checkpoint(state)}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  defp apply_parts(state, parts) do
    values =
      Enum.reduce(parts, state.values, fn
        {:cells, cells}, acc -> %{acc | blocks: apply_cells(acc.blocks, cells)}
        {k, v}, acc -> %{acc | k => v}
      end)

    %{state | values: values}
  end

  defp cells_parts(cells) when map_size(cells) == 0, do: []
  defp cells_parts(cells) when is_map(cells), do: [{:cells, cells}]

  # The sparse image omits flat-terrain blocks.
  defp apply_cells(blocks, cells) do
    Enum.reduce(cells, blocks, fn {{_, y, _} = pos, block}, acc ->
      if block == Chunk.base(y), do: Map.delete(acc, pos), else: Map.put(acc, pos, block)
    end)
  end

  defp maybe_checkpoint(%{appended: appended} = state) when appended < @checkpoint_bytes,
    do: state

  defp maybe_checkpoint(state) do
    case RegionLog.checkpoint(state.log, state.values) do
      {:ok, log} -> %{state | log: log, appended: 0}
      # A failed compaction keeps the (still valid) log; retry after more appends.
      {:error, _} -> %{state | appended: div(@checkpoint_bytes, 2)}
    end
  end
end
