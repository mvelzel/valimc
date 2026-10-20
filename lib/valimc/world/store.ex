defmodule Valimc.World.Store do
  use GenServer, restart: :temporary
  alias Valimc.World.{Chunk, Containers, ItemLedger, Items, MiningRecord, RegionLog}

  @moduledoc """
  Independently supervised resource I/O with one monitored owner and fenced writes.

  Durable state lives in a `RegionLog` directory (`r.X.Z/`). Every write is one
  frame: block changes as `{:cells, %{position => block}}` and full values for
  `{:items, bytes}` and `{:containers, bytes}`, so a mining commit changing all
  three is atomic with one fsync. Checkpoints hold the sparse block image.
  The log is checkpointed once appended frames exceed `:store_checkpoint_bytes`. Legacy
  per-file snapshots (`r.X.Z.etf/.items/.containers/.mining`) are imported once.
  """
  @max_batch 256
  @max_commit_cells 4096
  # Imported parts (VMC-021e): `block_entities` (`position => {type_id, nbt}`,
  # owner-loaded); `chunk_extras` (`chunk => nbt`, vanilla chunk data ValiMC does
  # not model) and `entities` (`chunk => nbt`, preserved vanilla entities) are kept
  # for export only; `light` (`chunk => image`, VMC-021e5) is owner-loaded.
  @empty %{
    blocks: %{},
    columns: %{},
    items: nil,
    containers: nil,
    ticks: nil,
    block_entities: %{},
    chunk_extras: %{},
    entities: %{},
    light: %{}
  }
  @imported [:columns, :items, :containers, :block_entities, :chunk_extras, :entities, :light]
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

  @doc "Imported and generated column images (`chunk => image`) of the region (VMC-021c)."
  def load_columns(pid), do: GenServer.call(pid, :load_columns)

  @doc """
  Persist generated column images (`chunk => image`, VMC-024d) before the region
  serves them; with a world path the frame is durable when this returns.
  """
  def put_columns(pid, lease, columns) when is_map(columns),
    do: GenServer.call(pid, {:put_columns, lease, columns}, 60_000)

  @doc """
  Write a new region's log with imported column images (`chunk => image`), offline:
  the region must have no log yet and no owner may run (VMC-021).
  """
  def import_columns(base, key, columns) when is_map(columns),
    do: import_region(base, key, %{columns: columns})

  @doc """
  Write a new region's log from imported parts (VMC-021e), offline: `columns`,
  `items` and `containers` bytes, `block_entities`, `chunk_extras`, `entities`.
  """
  def import_region(base, key, parts) when is_map(parts) do
    dir = log_dir(base, key)

    cond do
      not Enum.all?(Map.keys(parts), &(&1 in @imported)) ->
        {:error, :invalid_import_parts}

      File.exists?(dir) ->
        {:error, :region_exists}

      true ->
        with {:ok, log, _} <- RegionLog.open(dir),
             {:ok, log} <- RegionLog.checkpoint(log, Map.merge(@empty, parts)) do
          RegionLog.close(log)
        end
    end
  end

  @doc "Imported chunks' stored light (`chunk => image`, VMC-021e5)."
  def load_light(pid), do: GenServer.call(pid, :load_light)

  @doc "Preserved vanilla block entities (`position => {type_id, nbt}`, VMC-021e)."
  def load_block_entities(pid), do: GenServer.call(pid, :load_block_entities)

  def load_containers(pid), do: GenServer.call(pid, :load_containers)

  @doc "Scheduled block ticks (VMC-066) as saved by `commit_ticks/5`."
  def load_ticks(pid), do: GenServer.call(pid, :load_ticks)

  @doc "Persist the region's scheduled ticks (absolute list); acknowledged with `:ticks_saved`."
  def commit_ticks(pid, lease, entries, {owner, epoch}, token) when is_list(entries),
    do: GenServer.cast(pid, {:ticks, lease, entries, {owner, epoch}, token})

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
  def durable(base, key, part)
      when part in [
             :blocks,
             :columns,
             :items,
             :containers,
             :block_entities,
             :chunk_extras,
             :entities,
             :light
           ] do
    dir = log_dir(base, key)

    values =
      if File.dir?(dir, [:raw]) do
        {:ok, recovered} = RegionLog.read(dir)
        fold(recovered)
      else
        {:ok, values} = import_v1(base, key)
        values
      end

    Map.fetch!(Map.merge(@empty, values), part)
  end

  @impl true
  def init({key, owner}) do
    {:ok,
     %{
       base: Valimc.config(:world_path, key),
       key: key,
       log: nil,
       values: @empty,
       appended: 0,
       checkpoint_bytes: Valimc.config(:store_checkpoint_bytes, key),
       checkpointing: nil,
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
  def handle_call(:load_columns, _from, state), do: {:reply, state.values.columns, state}

  def handle_call(:load_light, _from, state), do: {:reply, state.values.light, state}

  def handle_call(:load_block_entities, _from, state),
    do: {:reply, state.values.block_entities, state}

  def handle_call({:flush, lease, cells}, _from, %{lease: lease} = state) do
    {result, state} = write(state, cells_parts(cells))
    {:reply, result, state}
  end

  def handle_call({:flush, _, _}, _from, state), do: {:reply, {:error, :stale_store_lease}, state}

  def handle_call({:put_columns, lease, columns}, _from, %{lease: lease} = state) do
    {result, state} = write(state, [{:columns, columns}])
    {:reply, result, state}
  end

  def handle_call({:put_columns, _, _}, _from, state),
    do: {:reply, {:error, :stale_store_lease}, state}

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

  def handle_call(:load_ticks, _from, state),
    do: {:reply, Map.get(state.values, :ticks) || [], state}

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

  # Group commit: every commit cast already queued under this lease joins one
  # frame with one `datasync`; acknowledgements follow in arrival order. Frames
  # carry absolute values, so the batch keeps merged cells and the last items and
  # containers. One owner holds the lease and never casts while it waits in a
  # call, so taking commit casts ahead of other messages cannot reorder its writes.
  @impl true
  def handle_cast(message, %{lease: lease} = state)
      when elem(message, 0) in [:snapshot, :items, :mining, :containers, :ticks] and
             elem(message, 1) == lease do
    batch = [message | drain(lease, @max_batch - 1, [])]
    Valimc.Metrics.add(:store_batches)
    Valimc.Metrics.add(:store_batch_commits, length(batch))

    {result, written, state} =
      case batch_parts(state.key, batch) do
        {:ok, parts} ->
          {result, state} = write(state, parts)
          {result, true, state}

        {:invalid, reason} ->
          {{:error, reason}, false, state}
      end

    if result != :ok do
      require Logger
      Logger.error("Region commit failed: #{inspect(result)}")
    end

    for message <- batch, do: acknowledge(message, result)

    # An append that failed may have left a torn frame; only recovery may continue.
    case result do
      {:error, reason} when written and state.log != nil ->
        {:stop, {:storage_failed, reason}, state}

      _ ->
        {:noreply, state}
    end
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

  def handle_cast({:ticks, _, _, {owner, epoch}, token}, state) do
    send(owner, {:resource, epoch, {:ticks_saved, self(), token, {:error, :stale_store_lease}}})
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

  def handle_info({:checkpointed, ref, result}, %{checkpointing: ref} = state) do
    Valimc.Metrics.add(if result == :ok, do: :store_checkpoints, else: :store_checkpoint_failures)

    # A failed checkpoint leaves the (still valid) log; retry after more appends.
    appended =
      if result == :ok,
        do: state.appended,
        else: max(state.appended, div(state.checkpoint_bytes, 2))

    {:noreply, %{state | checkpointing: nil, appended: appended}}
  end

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
      with {:ok, imported} <- import_v1(state.base, state.key),
           values = Map.merge(@empty, imported),
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
    # Checkpoints written before a part existed lack its key.
    Enum.reduce(frames, Map.merge(@empty, checkpoint || %{}), fn %{ops: ops}, values ->
      Enum.reduce(ops, values, fn
        {:cells, cells}, acc ->
          %{acc | blocks: apply_cells(acc.blocks, cells, acc.columns)}

        {:columns, columns}, acc ->
          %{acc | columns: Map.merge(acc.columns, columns)}

        {part, value}, acc
        when part in [
               :blocks,
               :items,
               :containers,
               :ticks,
               :block_entities,
               :chunk_extras,
               :entities
             ] ->
          %{acc | part => value}

        _, acc ->
          acc
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

  defp drain(_lease, 0, acc), do: Enum.reverse(acc)

  defp drain(lease, left, acc) do
    receive do
      {:"$gen_cast", {tag, ^lease, _, _, _} = message}
      when tag in [:snapshot, :mining, :containers, :ticks] ->
        drain(lease, left - 1, [message | acc])

      {:"$gen_cast", {:items, ^lease, _, _, _, _} = message} ->
        drain(lease, left - 1, [message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp batch_parts(key, batch) do
    folded =
      Enum.reduce_while(batch, %{cells: %{}, items: nil, containers: nil, ticks: nil}, fn message,
                                                                                          acc ->
        case fold_commit(key, message, acc) do
          {:ok, acc} -> {:cont, acc}
          error -> {:halt, error}
        end
      end)

    with %{} <- folded,
         {:ok, items} <- encode_items(key, folded.items),
         {:ok, containers} <- encode_containers(key, folded.containers) do
      {:ok,
       cells_parts(folded.cells) ++
         if(items, do: [{:items, items}], else: []) ++
         if(containers, do: [{:containers, containers}], else: []) ++
         if(folded.ticks, do: [{:ticks, folded.ticks}], else: [])}
    else
      # A batch holding a joint commit reports it as an invalid proposal.
      {:error, reason} ->
        if Enum.any?(batch, &(elem(&1, 0) == :mining)),
          do: {:invalid, :invalid_mining_proposal},
          else: {:invalid, reason}
    end
  end

  defp fold_commit(_key, {:snapshot, _, cells, _, _}, acc) when is_map(cells),
    do: {:ok, %{acc | cells: Map.merge(acc.cells, cells)}}

  defp fold_commit(_key, {:items, _, snapshot, receipts, _, _}, acc),
    do: {:ok, %{acc | items: {snapshot, receipts}}}

  defp fold_commit(_key, {:ticks, _, entries, _, _}, acc) when is_list(entries),
    do: {:ok, %{acc | ticks: entries}}

  defp fold_commit(_key, {:containers, _, containers, _, _}, acc),
    do: {:ok, %{acc | containers: containers}}

  defp fold_commit(key, {:mining, _, %{changes: changes} = proposal, _, _}, acc)
       when is_map(changes) and map_size(changes) <= @max_commit_cells do
    if Enum.all?(changes, &valid_cell?(key, &1)) do
      items = {Map.take(proposal, [:records, :ledger]), proposal.receipts}

      {:ok,
       %{
         acc
         | cells: Map.merge(acc.cells, changes),
           items: items,
           containers: Map.get(proposal, :containers, acc.containers)
       }}
    else
      {:error, :invalid_mining_proposal}
    end
  end

  defp fold_commit(_, _, _), do: {:error, :invalid_commit}

  defp valid_cell?(key, {{x, y, z}, block})
       when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(block),
       do:
         abs(x) <= 29_999_984 and abs(z) <= 29_999_984 and Chunk.valid_y?(y) and
           block >= 0 and block < Valimc.Protocol.Data.block_state_count() and
           Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key

  defp valid_cell?(_, _), do: false

  defp encode_items(_key, nil), do: {:ok, nil}

  defp encode_items(key, {%{records: records, ledger: ledger}, receipts}),
    do: ItemLedger.encode(key, records, receipts, ledger)

  defp encode_containers(_key, nil), do: {:ok, nil}
  defp encode_containers(key, containers), do: Containers.encode(key, containers)

  defp acknowledge({:snapshot, _, _, {owner, epoch}, revision}, result),
    do: send(owner, {:resource, epoch, {:saved, self(), revision, result}})

  defp acknowledge({:items, _, _, _, {owner, epoch}, token}, result),
    do: send(owner, {:resource, epoch, {:items_saved, self(), token, result}})

  defp acknowledge({:mining, _, _, {owner, epoch}, token}, result),
    do: send(owner, {:resource, epoch, {:mining_saved, self(), token, result}})

  defp acknowledge({:ticks, _, _, {owner, epoch}, token}, result),
    do: send(owner, {:resource, epoch, {:ticks_saved, self(), token, result}})

  defp acknowledge({:containers, _, _, {owner, epoch}, token}, result),
    do: send(owner, {:resource, epoch, {:containers_saved, self(), token, result}})

  # Append one frame of full values; without a world path, keep them in memory.
  defp write(state, []), do: {:ok, state}
  defp write(%{log: nil} = state, parts), do: {:ok, apply_parts(state, parts)}

  defp write(state, parts) do
    case RegionLog.append(state.log, [parts]) do
      {:ok, log, _lsn} ->
        bytes = :erlang.external_size(parts)

        for {part, _} <- parts, part != :columns do
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
        {:cells, cells}, acc -> %{acc | blocks: apply_cells(acc.blocks, cells, acc.columns)}
        {:columns, columns}, acc -> %{acc | columns: Map.merge(acc.columns, columns)}
        {k, v}, acc -> %{acc | k => v}
      end)

    %{state | values: values}
  end

  defp cells_parts(cells) when map_size(cells) == 0, do: []
  defp cells_parts(cells) when is_map(cells), do: [{:cells, cells}]

  # The sparse image omits flat-terrain blocks, except in imported chunks, whose
  # base is their column image rather than flat terrain.
  defp apply_cells(blocks, cells, columns) do
    Enum.reduce(cells, blocks, fn {{x, y, z} = pos, block}, acc ->
      flat? = block == Chunk.base(y) and not Map.has_key?(columns, {div16(x), div16(z)})
      if flat?, do: Map.delete(acc, pos), else: Map.put(acc, pos, block)
    end)
  end

  defp div16(v), do: Integer.floor_div(v, 16)

  defp maybe_checkpoint(%{appended: appended, checkpoint_bytes: limit} = state)
       when appended < limit,
       do: state

  # Checkpoints are written by a linked task from the immutable values while the
  # writer keeps appending to the segment `begin_checkpoint/1` rotated to. If they
  # keep failing, a synchronous checkpoint caps the log at 4x the threshold.
  defp maybe_checkpoint(%{checkpointing: ref} = state) when ref != nil do
    if state.appended < 4 * state.checkpoint_bytes do
      state
    else
      case RegionLog.checkpoint(state.log, state.values) do
        {:ok, log} -> %{state | log: log, appended: 0}
        {:error, _} -> state
      end
    end
  end

  defp maybe_checkpoint(state) do
    case RegionLog.begin_checkpoint(state.log) do
      {:ok, log, job} ->
        writer = self()
        ref = make_ref()
        values = state.values

        {:ok, _} =
          Task.start_link(fn ->
            result =
              try do
                RegionLog.write_checkpoint(job, values)
              rescue
                error -> {:error, error}
              end

            send(writer, {:checkpointed, ref, result})
          end)

        %{state | log: log, appended: 0, checkpointing: ref}

      {:error, _} ->
        %{state | appended: div(state.checkpoint_bytes, 2)}
    end
  end
end
