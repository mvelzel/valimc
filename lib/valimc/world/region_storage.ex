defmodule Valimc.World.RegionStorage do
  @moduledoc """
  A region owner's durability (VMC-077f): keyed change records, one frame per
  commit tick on the world's shared write-ahead log (`Valimc.Storage.Log`),
  and a checkpoint file that folds them (`Valimc.Storage.Checkpoint`).

  Records are keyed values; a frame puts or deletes keys:

  | Key | Value |
  |---|---|
  | `{:column, chunk}` | the chunk's column image (generation, `/fillbiome`, checkpoints) |
  | `{:cell, position}` | a block state changed since the column image |
  | `{:post, chunk}` | a generated chunk's post-processing marks and fluid ticks, until it first ticks |
  | `{:structures, chunk}` | the starts a generated chunk references whose structures override spawns (VMC-042b) |
  | `{:entity, uuid}` | an entity's record (an item, an orb) |
  | `{:handoff, field}`, `{:handoff_in, source}` | the entity handoff ledger: sequence, outgoing intent, incoming receipts |
  | `{:container, position}`, `{:containers, :sequence}` | containers |
  | `{:ticks, chunk}`, `{:ticks, :shift}` | a chunk's scheduled block ticks (`ScheduledTicks.record/1`) |
  | `{:block_entity, position}` | a preserved block entity, `{type, nbt}` |
  | `:game_tick` | the region's game tick when the frame was cut |

  The owner adopts every change in memory at once and replies at once (D2).
  Every 50 ms (`@commit_ms`) the changes since the last frame are one frame:
  cells and columns as they were made, every other part as the records that
  changed, found in O(changes) (`diff_parts/2`). Only the replies of entity
  handoffs between owners wait for their frame to be durable
  (`after_durable/2`), so a crash can lose the last frames but never one half
  of a handoff.

  A cut frame waits in the section's outbox; its group process sends the
  frames of all its sections from one commit as one record (VMC-077j,
  `take/2`), on the stripe of its `route`, so changes that span sections are
  durable together. A section moves to another group only once its frames
  are durable (VMC-077y), so they never wait on two stripes.

  Item motion (position, velocity) goes into a frame at most once a second.
  Counters that move every tick (an item's age and delays, a furnace's
  remaining burn and progress) stay out of frames unless they cross zero; a
  checkpoint saves them, at the latest five minutes after they moved, like
  vanilla's autosave. A crash can roll back only motion and counters.

  A checkpoint holds every record with cells folded into column images taken
  from the owner's Rust blocks (relit alone, VMC-077c) and replaces the file;
  the log then forgets the frames it holds. Frames come only from the log,
  which reads exactly the section's (`Log.frames/3`). Every checkpoint is
  written by a task holding the file's lock, never in the group: the writes
  of one file never overlap, and a section loading again waits for the one in
  progress. Checkpoints follow appended bytes,
  frame count, moved counters, `/save-all` and unload; `/save-off` pauses
  them, not the log. A world without a path keeps everything in memory.
  """
  require Logger
  alias Valimc.Storage.{Checkpoint, Log}
  alias Valimc.World.{BlockEntities, Blocks, Containers, ScheduledTicks}
  alias Valimc.Entity.Store

  @commit_ms 50
  @checkpoint_bytes 1024 * 1024
  @checkpoint_frames 1200
  # Vanilla autosaves every 6000 ticks.
  @autosave_ms 300_000
  # Item motion is written at most this often, like the item checkpoints before.
  @motion_ms 1000
  @parts [:items, :containers, :ticks, :block_entities, :post, :structures]
  # Owner frames stay well below the log's frame cap (world-core E1).
  @frame_bytes 8 * 1024 * 1024

  defstruct [
    :base,
    :owner,
    :path,
    seq: 0,
    pending: %{},
    waits: [],
    in_flight: %{},
    committed: %{},
    # `{written, current}` records of changes that wait (`diff_parts/2`).
    deferred: %{},
    dirty_chunks: MapSet.new(),
    checkpoint_seq: 0,
    since_checkpoint: 0,
    frames_since_checkpoint: 0,
    checkpointing: nil,
    requested: false,
    counters_since: nil,
    motion_waiting: false,
    motion_at: 0,
    # Frames cut but not yet sent (`[{owner, seq, frame}]`, newest first).
    outbox: [],
    # The key whose stripe the section's group commits to.
    route: nil
  ]

  def commit_ms, do: @commit_ms

  @doc """
  Open the storage of section `key` of `dimension`: its checkpoint and the
  frames after it. `{:ok, storage, loaded}` with the section's parts, or
  `{:error, reason}`; a section stored before VMC-077f is refused (D4).
  """
  def open(dimension, key) do
    base = Valimc.config(:world_path, key)
    owner = {:region, dimension, key}

    if base == nil do
      {:ok, %__MODULE__{owner: owner, route: owner}, restore(%{}, false)}
    else
      path = Checkpoint.path(base, owner)

      with :ok <- current_format(path, key),
           :ok <- await_checkpoint(path),
           {:ok, checkpoint} <- Checkpoint.read(path),
           {seq, records} =
             if(checkpoint, do: {checkpoint.seq, checkpoint.records}, else: {0, %{}}),
           frames when is_list(frames) <- Log.frames(base, owner, seq) do
        records = fold(records, ops(frames))
        last = frames |> List.last({seq, nil}) |> elem(0)

        storage = %__MODULE__{
          base: base,
          owner: owner,
          route: owner,
          path: path,
          seq: last,
          checkpoint_seq: seq,
          frames_since_checkpoint: last - seq
        }

        if last == seq, do: Log.covered(base, owner, seq)
        {:ok, storage, restore(records, true)}
      else
        {:error, _} = error -> error
      end
    end
  catch
    {:old_region_format, record} ->
      Logger.error(
        "Region #{inspect(key)} holds a record from before VMC-077h (#{inspect(record)}); " <>
          "ValiMC no longer reads it (no migration)"
      )

      {:error, {:old_region_format, record}}
  end

  # D4: the per-region logs and per-file snapshots of older worlds are refused.
  defp current_format(path, {rx, rz}) do
    dir = Path.dirname(path)

    old =
      Enum.filter(
        [Path.join(dir, "r.#{rx}.#{rz}")] ++
          for(s <- ~w(etf items containers mining), do: Path.join(dir, "r.#{rx}.#{rz}.#{s}")),
        &File.exists?(&1, [:raw])
      )

    if old == [] do
      :ok
    else
      Logger.error(
        "Region #{inspect({rx, rz})} is stored in a format from before VMC-077f; " <>
          "ValiMC no longer reads it (no migration): #{Enum.join(old, ", ")}"
      )

      {:error, {:old_region_format, old}}
    end
  end

  ## Changes

  @doc "Block changes (`position => state`), as made."
  def cells(storage, changes) when map_size(changes) == 0, do: storage

  def cells(storage, changes) do
    pending =
      Enum.reduce(changes, storage.pending, fn {pos, block}, acc ->
        Map.put(acc, {:cell, pos}, block)
      end)

    chunks =
      Enum.reduce(Map.keys(changes), storage.dirty_chunks, fn {x, _, z}, acc ->
        MapSet.put(acc, chunk(x, z))
      end)

    %{storage | pending: pending, dirty_chunks: chunks}
  end

  @doc """
  Whole column images (`chunk => image`) replacing their chunks' blocks. A
  checkpoint keeps them as they are unless cells change their chunk later.
  """
  def columns(storage, columns) when map_size(columns) == 0, do: storage

  def columns(storage, columns) do
    pending =
      Enum.reduce(columns, drop_cells(storage.pending, columns), fn {chunk, image}, acc ->
        Map.put(acc, {:column, chunk}, image)
      end)

    %{storage | pending: pending}
  end

  # Records without the cells of `chunks` (a map or set keyed by chunk): one
  # pass, however many chunks.
  defp drop_cells(records, chunks) when map_size(chunks) == 0, do: records

  defp drop_cells(records, chunks) do
    if Enum.any?(records, &match?({{:cell, _}, _}, &1)),
      do:
        Map.reject(records, fn {key, _} ->
          match?({:cell, _}, key) and Map.has_key?(chunks, cell_chunk(key))
        end),
      else: records
  end

  @doc """
  Run `item` once everything adopted so far is durable: `{:reply, from,
  reply}` or `{:effect, term}` (returned by `durable/2`). Only entity
  handoffs between owners need this.
  """
  def after_durable(storage, item), do: %{storage | waits: storage.waits ++ [item]}

  @doc "Whether frames or waits are outstanding (an owner with them does not unload)."
  def busy?(storage),
    do:
      map_size(storage.in_flight) > 0 or storage.waits != [] or storage.outbox != [] or
        storage.checkpointing != nil

  ## Commits

  @doc """
  Cut a frame of everything changed since the last one; `parts` are the
  owner's current keyed parts (`parts/1` of the owner state). Returns
  `{storage, released}`: without a world path waits are released at once.
  """
  def commit(storage, parts) do
    storage = diff_parts(storage, parts)

    cond do
      storage.base == nil ->
        {%{storage | pending: %{}, waits: []}, storage.waits}

      map_size(storage.pending) == 0 and storage.waits == [] ->
        {storage, []}

      map_size(storage.pending) == 0 ->
        # Waits on frames already sent are released with the last of them.
        case Map.keys(storage.in_flight) do
          [] ->
            {%{storage | waits: []}, storage.waits}

          seqs ->
            last = Enum.max(seqs)
            in_flight = Map.update!(storage.in_flight, last, &(&1 ++ storage.waits))
            {%{storage | in_flight: in_flight, waits: []}, []}
        end

      true ->
        ops = Enum.map(storage.pending, fn {key, value} -> op(key, value) end)
        {sent, bytes} = send_frames(storage, ops)

        {%{
           sent
           | pending: %{},
             waits: [],
             in_flight: Map.put(storage.in_flight, sent.seq, storage.waits),
             since_checkpoint: storage.since_checkpoint + bytes,
             frames_since_checkpoint: storage.frames_since_checkpoint + 1
         }, []}
    end
  end

  defp op(key, :deleted), do: {:del, key}
  defp op(key, value), do: {:put, key, value}

  # One frame, or several below the cap when one tick changed very much, into
  # the outbox.
  defp send_frames(storage, ops) do
    binary = :erlang.term_to_binary(ops)

    chunks =
      if byte_size(binary) <= @frame_bytes,
        do: [binary],
        else:
          ops
          |> Enum.chunk_every(max(1, div(length(ops) * @frame_bytes, byte_size(binary) * 2)))
          |> Enum.map(&:erlang.term_to_binary/1)

    Enum.reduce(chunks, {storage, 0}, fn frame, {acc, bytes} ->
      seq = acc.seq + 1

      {%{acc | seq: seq, outbox: [{acc.owner, seq, frame} | acc.outbox]},
       bytes + byte_size(frame)}
    end)
  end

  @doc """
  The outbox's frames, oldest first, to send on the stripe of the group's
  route, and the storage that has sent them.
  """
  def take(storage), do: {Enum.reverse(storage.outbox), %{storage | outbox: []}}

  @doc """
  Whether frames that were sent are not yet durable (those still in the
  outbox are not sent: they are the oldest frames not yet sent onwards).
  """
  def sending?(%{outbox: []} = storage), do: storage.in_flight != %{}

  def sending?(storage) do
    {_, first, _} = List.last(storage.outbox)
    Enum.any?(storage.in_flight, fn {seq, _} -> seq < first end)
  end

  @doc "Send the outbox now, on the section's own route, and wait until it is appended."
  def send_now(storage, sync \\ true)
  def send_now(%{base: nil} = storage, _sync), do: storage

  def send_now(storage, sync) do
    {frames, storage} = take(storage)
    if frames != [], do: Log.commit_group(storage.base, storage.route, frames, self())

    if sync, do: :ok = Log.sync(storage.base, storage.route)
    storage
  end

  @doc """
  Whether a reply waits on a frame (an entity handoff's): a section that
  unloads with none needs no wait for its last frames, whose checkpoint
  holds them (`checkpoint/4` with `wait: :locked`).
  """
  def waiting?(storage),
    do: storage.waits != [] or Enum.any?(storage.in_flight, fn {_, waits} -> waits != [] end)

  @doc "A frame is durable: `{storage, items}` its waits (and earlier ones) to run."
  def durable(storage, seq) do
    {done, in_flight} = Map.split_with(storage.in_flight, fn {s, _} -> s <= seq end)
    items = done |> Enum.sort() |> Enum.flat_map(&elem(&1, 1))
    {%{storage | in_flight: in_flight}, items}
  end

  ## Checkpoints

  @doc "Ask for a checkpoint as soon as one may run (`/save-all`)."
  def request_checkpoint(storage), do: %{storage | requested: true}

  @doc """
  Whether a checkpoint is due: requested, enough bytes or frames since the last
  one, or counters moved five minutes ago; none running, every frame cut and
  durable, and saving not paused.
  """
  def checkpoint_due?(storage) do
    storage.base != nil and storage.checkpointing == nil and map_size(storage.pending) == 0 and
      map_size(storage.in_flight) == 0 and storage.outbox == [] and Valimc.World.Saving.auto?() and
      (storage.requested or
         (storage.seq > storage.checkpoint_seq and
            (storage.since_checkpoint >= @checkpoint_bytes or
               storage.frames_since_checkpoint >= @checkpoint_frames)) or
         (storage.counters_since != nil and
            System.monotonic_time(:millisecond) - storage.counters_since >= @autosave_ms))
  end

  @doc """
  Checkpoint `parts` (the owner's current parts, everything cut into frames
  up to `storage.seq`) and `blocks`. A task holding the file's lock waits
  until the log holds the section's frames, folds the last checkpoint and
  the frames after it with the images of the dirty chunks, writes the file
  and reports what it covers to the log. By `wait`:

  - none: the task sends `wrap.({:checkpointed, ref, seq, result})` to the
    owner (a section's epoch tag, so it reaches the section wherever it
    moved meanwhile);
  - `:written` (a flush, a shutdown): this returns once the file is written;
  - `:locked` (an unloading section): this returns once the task holds the
    lock, so a load after it waits for the write (`await_checkpoint/1`).
  """
  def checkpoint(storage, parts, blocks, opts \\ []) do
    # A checkpoint still running may land after this one; this one holds its
    # chunks too.
    chunks =
      case storage.checkpointing do
        {_, running} -> MapSet.union(storage.dirty_chunks, running)
        nil -> storage.dirty_chunks
      end

    job = %{
      base: storage.base,
      owner: storage.owner,
      route: storage.route,
      path: storage.path,
      seq: storage.seq,
      records: parts |> records() |> Map.put(:game_tick, parts.game_tick),
      images:
        for(
          chunk <- chunks,
          {:ok, image} <- [Blocks.column_image(blocks, chunk)],
          image != nil,
          into: %{},
          do: {chunk, image}
        ),
      sky: Valimc.World.Dimension.facts().sky_light
    }

    # Changes not yet in a frame still go into the next one; the checkpoint
    # also holds the motion and counters that waited, so frames need not.
    storage = diff_parts(storage, parts)

    storage = %{
      baseline(storage, parts)
      | dirty_chunks: MapSet.new(),
        requested: false,
        counters_since: nil
    }

    owner = self()
    ref = make_ref()
    wait = opts[:wait]

    report =
      case wait do
        nil -> Keyword.get(opts, :wrap, & &1)
        :written -> & &1
        :locked -> nil
      end

    {:ok, pid} =
      Task.start(
        Valimc.World.Dimension.bind(fn ->
          locked(job.path, fn ->
            if wait == :locked, do: send(owner, {ref, :locked})
            result = write_checkpoint(job)
            if report, do: send(owner, report.({:checkpointed, ref, job.seq, result}))
          end)
        end)
      )

    await(%{storage | checkpointing: {ref, chunks}}, ref, pid, wait)
  end

  defp await(storage, _ref, _pid, nil), do: storage

  defp await(storage, ref, pid, wait) do
    monitor = Process.monitor(pid)

    receive do
      {^ref, :locked} when wait == :locked ->
        Process.demonitor(monitor, [:flush])
        storage

      {:checkpointed, ^ref, seq, result} ->
        Process.demonitor(monitor, [:flush])
        checkpointed(storage, ref, seq, result)

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        Logger.error("Region checkpoint failed: #{inspect(reason)}")
        checkpointed(storage, ref, storage.seq, {:error, reason})
    end
  end

  @doc "A checkpoint task finished."
  def checkpointed(%{checkpointing: {ref, _}} = storage, ref, seq, :ok),
    do: %{
      storage
      | checkpointing: nil,
        checkpoint_seq: seq,
        since_checkpoint: 0,
        frames_since_checkpoint: storage.seq - seq
    }

  # A failed checkpoint leaves the log (only waiting motion and counters are
  # lost); its chunks stay dirty for the next one.
  def checkpointed(%{checkpointing: {ref, chunks}} = storage, ref, _seq, {:error, _}),
    do: %{storage | checkpointing: nil, dirty_chunks: MapSet.union(storage.dirty_chunks, chunks)}

  def checkpointed(storage, _ref, _seq, _result), do: storage

  # In the task: the durable records through `seq` (the last checkpoint and
  # the frames after it, read from the log once it holds them), with the
  # owner's parts as they were at `seq` and the dirty chunks' images, relit
  # alone, in place of their cells. A checkpoint never replaces a newer one.
  defp write_checkpoint(job) do
    result = fold_checkpoint(job)

    if result == :ok do
      Log.covered(job.base, job.owner, job.seq)
      Valimc.Data.Metrics.add(:region_checkpoints)
    else
      Logger.error("Region checkpoint failed: #{inspect(result)}")
    end

    result
  end

  defp fold_checkpoint(job) do
    :ok = Log.sync(job.base, job.route)

    with {:ok, previous} <- Checkpoint.read(job.path),
         {seq, records} when seq <= job.seq <-
           if(previous, do: {previous.seq, previous.records}, else: {0, %{}}),
         frames when is_list(frames) <- Log.frames(job.base, job.owner, seq) do
      durable = fold(records, ops(Enum.filter(frames, &(elem(&1, 0) <= job.seq))))

      kept = Map.filter(durable, fn {key, _} -> match?({:column, _}, key) end)

      lit = Blocks.lit_images(job.images, job.sky)
      columns = for {chunk, image} <- lit, into: %{}, do: {{:column, chunk}, image}
      Checkpoint.write(job.path, job.seq, kept |> Map.merge(columns) |> Map.merge(job.records))
    else
      {newer, _} when is_integer(newer) -> :ok
      error -> error
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, reason}
  end

  # One checkpoint write of a file at a time: an unloading section's may
  # still run when it loads again. Only tasks hold the lock.
  defp locked(path, fun) do
    case Registry.register(Valimc.StorageRegistry, {:checkpoint, path}, nil) do
      {:ok, _} ->
        try do
          fun.()
        after
          Registry.unregister(Valimc.StorageRegistry, {:checkpoint, path})
        end

      {:error, {:already_registered, _}} ->
        :ok = await_checkpoint(path)
        locked(path, fun)
    end
  end

  # A section loads only once no checkpoint of its file is being written:
  # one that covers frames would otherwise hide them from it.
  defp await_checkpoint(path) do
    case Registry.lookup(Valimc.StorageRegistry, {:checkpoint, path}) do
      [] ->
        :ok

      [{pid, _}] ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> await_checkpoint(path)
        end
    end
  end

  ## Parts and records

  @doc """
  The owner's keyed parts for commits and checkpoints: `items` (an
  `Valimc.Entity.Store`), `containers`, `ticks` (a `ScheduledTicks`),
  `block_entities`, `post` (generated chunks' post-processing) and
  `game_tick`.

  A frame carries only what changed, found in O(changes): each part is
  described once as keyed maps of entries (`fields/2`), and only the entries
  that are no longer the terms last committed become records (an unchanged
  entry is the same term and compares at once). A change that may wait
  (`wait/4`) keeps its last written and its current record in `deferred`
  until it changes otherwise, or until the next motion pass writes it.
  """
  def diff_parts(storage, parts) do
    now = System.monotonic_time(:millisecond)
    full = storage.motion_waiting and now >= storage.motion_at

    {changes, committed} =
      Enum.reduce(@parts, {%{}, storage.committed}, fn part, {changes, committed} ->
        value = Map.fetch!(parts, part)

        case committed do
          %{^part => ^value} ->
            {changes, committed}

          _ ->
            {part_changes(part, committed[part], value, changes), Map.put(committed, part, value)}
        end
      end)

    # A motion pass writes what waited and has not changed again since.
    changes = if full, do: Map.merge(storage.deferred, changes), else: changes
    {pending, deferred, waits} = settle(storage.pending, storage.deferred, changes, full)

    storage = %{
      storage
      | pending: pending,
        deferred: deferred,
        committed: committed,
        motion_waiting: (storage.motion_waiting and not full) or :motion in waits,
        motion_at: if(full, do: now + @motion_ms, else: storage.motion_at),
        counters_since:
          if(:counters in waits and storage.counters_since == nil,
            do: now,
            else: storage.counters_since
          )
    }

    if map_size(storage.pending) > 0,
      do: %{storage | pending: Map.put(storage.pending, :game_tick, parts.game_tick)},
      else: storage
  end

  @doc "Take `parts` as what the log and checkpoint hold (after a load or a checkpoint)."
  def baseline(storage, parts) do
    %{
      storage
      | committed: Map.new(@parts, &{&1, Map.fetch!(parts, &1)}),
        deferred: %{},
        motion_waiting: false,
        motion_at: System.monotonic_time(:millisecond) + @motion_ms
    }
  end

  # Each stored part as keyed maps of its entries, each with how an entry
  # becomes `{record key, record}`.
  defp fields(:items, %Store{entries: entries, ledger: ledger}),
    do: [
      {entries, fn _id, entry -> {{:entity, entry.entity.uuid}, Store.record(entry)} end},
      {ledger.incoming, &{{:handoff_in, &1}, &2}},
      # Network ids are the VM's: a recovered intent delivers without them.
      {%{sequence: ledger.sequence, outgoing: ledger.outgoing},
       fn
         :outgoing, nil ->
           {{:handoff, :outgoing}, nil}

         :outgoing, o ->
           {{:handoff, :outgoing},
            %{o | records: Enum.map(o.records, &Map.delete(&1, :entity_id))}}

         :sequence, sequence ->
           {{:handoff, :sequence}, sequence}
       end}
    ]

  defp fields(:containers, %Containers{entries: entries, sequence: sequence}),
    do: [
      {entries, &{{:container, &1}, &2}},
      {%{sequence: sequence}, fn _, sequence -> {{:containers, :sequence}, sequence} end}
    ]

  defp fields(:ticks, %ScheduledTicks{containers: containers, shift: shift}),
    do: [
      {containers, &{{:ticks, &1}, ScheduledTicks.record(&2)}},
      {%{shift: shift}, fn _, shift -> {{:ticks, :shift}, shift} end}
    ]

  defp fields(:block_entities, %BlockEntities{entries: entries}),
    do: [{entries, fn pos, %{type: type, nbt: nbt} -> {{:block_entity, pos}, {type, nbt}} end}]

  defp fields(:post, post), do: [{post, &{{:post, &1}, &2}}]
  defp fields(:structures, structures), do: [{structures, &{{:structures, &1}, &2}}]

  # `changes` with the records of `part` that changed between its last
  # committed value and `value`: `key => {old, new}`, `new` `:deleted` for a
  # gone record, `old` nil for a new one. A chunk's old ticks are `:unknown`:
  # no wait depends on them, so they are not built.
  defp part_changes(part, previous, value, changes) do
    olds =
      if previous,
        do: Enum.map(fields(part, previous), &elem(&1, 0)),
        else: Stream.repeatedly(fn -> %{} end)

    before =
      if part == :ticks,
        do: fn _, _, _ -> :unknown end,
        else: fn record, key, entry -> elem(record.(key, entry), 1) end

    fields(part, value)
    |> Enum.zip(olds)
    |> Enum.reduce(changes, fn {{new, record}, old}, acc ->
      keyed_changes(old, new, &before.(record, &1, &2), record, acc)
    end)
  end

  defp keyed_changes(old, new, _before, _record, acc) when old === new, do: acc

  defp keyed_changes(old, new, before, record, acc) do
    acc =
      Enum.reduce(new, acc, fn {key, entry}, acc ->
        case old do
          %{^key => ^entry} ->
            acc

          %{^key => was} ->
            {record_key, after_record} = record.(key, entry)
            Map.put(acc, record_key, {before.(key, was), after_record})

          _ ->
            {record_key, after_record} = record.(key, entry)
            Map.put(acc, record_key, {nil, after_record})
        end
      end)

    Enum.reduce(old, acc, fn {key, entry}, acc ->
      if Map.has_key?(new, key),
        do: acc,
        else: Map.put(acc, elem(record.(key, entry), 0), {before.(key, entry), :deleted})
    end)
  end

  # `{pending, deferred, waits}`: changed records the next frame must carry go
  # to `pending`; one whose change may wait keeps `{written, current}` (the
  # record the last frame wrote, the one it would write now) in `deferred`,
  # and `waits` says what waits (`:motion`, `:counters`).
  defp settle(pending, deferred, changes, full) do
    {pending, deferred, waits} =
      Enum.reduce(changes, {pending, deferred, []}, fn {key, {before, value}},
                                                       {pending, deferred, waits} ->
        {written, waited} =
          case deferred do
            %{^key => {written, _}} -> {written, true}
            _ -> {before, false}
          end

        cond do
          # Back to what the last frame wrote while it waited: nothing to write.
          value == written and waited ->
            {Map.delete(pending, key), Map.delete(deferred, key), waits}

          value == written ->
            {pending, deferred, waits}

          value == :deleted or written in [nil, :unknown, :deleted] ->
            {Map.put(pending, key, value), Map.delete(deferred, key), waits}

          true ->
            case wait(key, written, value, full) do
              nil -> {Map.put(pending, key, value), Map.delete(deferred, key), waits}
              kind -> {pending, Map.put(deferred, key, {written, value}), [kind | waits]}
            end
        end
      end)

    {pending, deferred, Enum.uniq(waits)}
  end

  # Whether a changed record may wait: `:counters` when only its tick counters
  # moved (an item's age and delays, a furnace burning on), `:motion` when an
  # item only moved and this is not a motion pass; nil when it goes now.
  defp wait({:entity, _}, %{motion: _} = old, %{motion: _} = new, full) do
    cond do
      counters(old) == counters(new) -> :counters
      not full and moved(old) == moved(new) -> :motion
      true -> nil
    end
  end

  # A body (VMC-015i) that only moved waits for the motion pass, as an item.
  defp wait({:entity, _}, %{kind: kind, mob: _} = old, %{kind: kind, mob: _} = new, full)
       when kind in [:mob, :object] do
    if not full and travelled(old) == travelled(new), do: :motion
  end

  defp wait({:container, _}, %{cooking: %{} = a} = old, %{cooking: %{} = b} = new, _full),
    do: if(%{old | cooking: burning(a)} == %{new | cooking: burning(b)}, do: :counters)

  defp wait(_key, _old, _new, _full), do: nil

  defp counters(%{motion: motion} = record),
    do: %{record | motion: %{motion | age: 0, pickup_delay: 0, portal_cooldown: 0}}

  defp moved(record) do
    %{motion: motion} = record = counters(record)
    %{record | x: 0, y: 0, z: 0, motion: %{motion | velocity: nil, on_ground: nil}}
  end

  defp travelled(record),
    do: %{
      record
      | x: 0,
        y: 0,
        z: 0,
        velocity: nil,
        rotation: nil,
        on_ground: nil,
        mob: %{record.mob | motion: nil, ai: nil}
    }

  # Burning out or finishing is a change; burning on is not.
  defp burning(cooking),
    do: %{cooking | burn_left: cooking.burn_left > 0, progress: cooking.progress > 0}

  defp records(parts), do: Enum.reduce(@parts, %{}, &Map.merge(&2, part_records(&1, parts[&1])))

  @doc false
  def part_records(part, value),
    do:
      for(
        {entries, record} <- fields(part, value),
        {key, entry} <- entries,
        into: %{},
        do: record.(key, entry)
      )

  # Decoded frames (`[{seq, frame}]`), in order.
  defp ops(frames), do: Enum.map(frames, &:erlang.binary_to_term(elem(&1, 1), [:safe]))

  @doc """
  Records with `frames` (decoded ops lists, in order) applied. A frame's
  column image replaces its chunk's earlier cells, and holds no cell of a
  chunk it puts a column of (`columns/2`): the cells are kept apart, so a
  column drops them without passing over every other record.
  """
  def fold(records, []), do: records

  def fold(records, frames) do
    {cells, rest} = Map.split_with(records, fn {key, _} -> match?({:cell, _}, key) end)

    {cells, rest} =
      Enum.reduce(frames, {cells, rest}, fn ops, {cells, rest} ->
        columns = for {:put, {:column, chunk}, _} <- ops, into: %{}, do: {chunk, true}

        Enum.reduce(ops, {drop_cells(cells, columns), rest}, fn
          {:put, {:cell, _} = key, value}, {c, r} -> {Map.put(c, key, value), r}
          {:del, {:cell, _} = key}, {c, r} -> {Map.delete(c, key), r}
          {:put, key, value}, {c, r} -> {c, Map.put(r, key, value)}
          {:del, key}, {c, r} -> {c, Map.delete(r, key)}
        end)
      end)

    Map.merge(rest, cells)
  end

  # The region's parts from its records (the inverse of `fields/2`).
  defp restore(records, persistent) do
    {ticks, records} =
      Map.split_with(records, fn {key, _} ->
        match?({:ticks, {_, _}}, key) or key == {:ticks, :shift}
      end)

    empty = %{
      columns: %{},
      cells: %{},
      post_processing: %{},
      structures: %{},
      items: [],
      ledger: Store.empty_ledger(),
      containers: %Containers{},
      ticks: ScheduledTicks.from_records(ticks),
      block_entities: %{},
      game_tick: Map.get(records, :game_tick, 0),
      persistent: persistent
    }

    Enum.reduce(records, empty, fn
      {{:column, chunk}, image}, acc ->
        put_in(acc, [:columns, chunk], image)

      {{:cell, pos}, block}, acc ->
        put_in(acc, [:cells, pos], block)

      {{:post, chunk}, value}, acc ->
        put_in(acc, [:post_processing, chunk], value)

      {{:structures, chunk}, value}, acc ->
        put_in(acc, [:structures, chunk], value)

      {{:block_entity, pos}, value}, acc ->
        put_in(acc, [:block_entities, pos], value)

      {{:entity, _}, record}, acc ->
        %{acc | items: [record | acc.items]}

      {:game_tick, _}, acc ->
        acc

      {{:handoff, field}, value}, acc when field in [:sequence, :outgoing] ->
        %{acc | ledger: Map.put(acc.ledger, field, value)}

      {{:handoff_in, source}, receipt}, acc ->
        update_in(acc.ledger.incoming, &Map.put(&1, source, receipt))

      {{:container, pos}, entry}, acc ->
        update_in(acc.containers.entries, &Map.put(&1, pos, entry))

      {{:containers, :sequence}, value}, acc ->
        put_in(acc.containers.sequence, value)

      # A record of an older format (D4): no migration, no legacy reader.
      {key, _}, _acc ->
        throw({:old_region_format, key})
    end)
    |> Map.update!(:items, &Enum.sort_by(&1, fn r -> r.uuid end))
  end

  defp chunk(x, z), do: {Integer.floor_div(x, 16), Integer.floor_div(z, 16)}
  defp cell_chunk({:cell, {x, _, z}}), do: chunk(x, z)

  ## Offline

  @imported [:columns, :cells, :items, :containers, :block_entities, :chunk_extras, :entities]

  @doc """
  Write a region offline (import, fixtures): its checkpoint from `parts`
  (`columns`, `cells`, `items` as records, `containers`, `block_entities` as
  `position => {type, nbt}`) and the export-only `chunk_extras` and `entities`
  in its side file. The region must not run; an existing one is refused.
  """
  def import(base, dimension, key, parts) when is_map(parts) do
    path = Checkpoint.path(base, {:region, dimension, key})

    cond do
      not Enum.all?(Map.keys(parts), &(&1 in @imported)) ->
        {:error, :invalid_import_parts}

      File.exists?(path) ->
        {:error, :region_exists}

      true ->
        records =
          for(
            {chunk, image} <- Map.get(parts, :columns, %{}),
            into: %{},
            do: {{:column, chunk}, image}
          )
          |> Map.merge(
            for {pos, block} <- Map.get(parts, :cells, %{}), into: %{}, do: {{:cell, pos}, block}
          )
          |> Map.merge(
            for {pos, value} <- Map.get(parts, :block_entities, %{}),
                into: %{},
                do: {{:block_entity, pos}, value}
          )
          |> Map.merge(part_records(:containers, Map.get(parts, :containers, %Containers{})))
          |> Map.merge(
            for record <- Map.get(parts, :items, []),
                into: %{},
                do: {{:entity, record.uuid}, Map.put_new(record, :kind, :item)}
          )

        extra = Map.take(parts, [:chunk_extras, :entities])

        with :ok <- Checkpoint.write(path, 0, records),
             do:
               if(extra == %{},
                 do: :ok,
                 else:
                   Valimc.Storage.DurableFile.write(
                     Checkpoint.extra(path),
                     :erlang.term_to_binary(extra)
                   )
               )
    end
  end

  @doc """
  The regions of `dimension` stored under `base`, offline: checkpoint files
  and regions the log holds frames of. A world stored before VMC-077f is refused.
  """
  def keys(base, dimension) do
    dir = Valimc.World.Dimension.storage(base, dimension)

    names =
      case File.ls(dir),
        do: (
          {:ok, names} -> names
          {:error, _} -> []
        )

    if old = Enum.find(names, &Regex.match?(~r/\Ar\.-?\d+\.-?\d+\z/, &1)) do
      {:error, {:old_region_format, Path.join(dir, old)}}
    else
      stored =
        for name <- names,
            [_, x, z] <- [Regex.run(~r/\Ar\.(-?\d+)\.(-?\d+)\.vmc\z/, name)],
            do: {String.to_integer(x), String.to_integer(z)}

      logged = for {{:region, ^dimension, key}, _, _} <- log_frames(base), do: key
      {:ok, Enum.sort(Enum.uniq(stored ++ logged))}
    end
  end

  @doc "Whether region `key` has been stored (a clean unload always leaves its checkpoint)."
  def stored?(base, dimension, key),
    do: File.exists?(Checkpoint.path(base, {:region, dimension, key}), [:raw])

  @doc """
  A region's durable parts offline (as `open/1` loads them): its checkpoint and
  the log's frames after it.
  """
  def read(base, dimension, key) do
    with {:ok, _seq, records} <- records(base, dimension, key),
         do: {:ok, restore(records, true)}
  catch
    {:old_region_format, record} -> {:error, {:old_region_format, record}}
  end

  @doc """
  A region's durable records offline, `{:ok, seq, records}` with `seq` its
  last frame: what a checkpoint written now must hold.
  """
  def records(base, dimension, key) do
    owner = {:region, dimension, key}

    with {:ok, checkpoint} <- Checkpoint.read(Checkpoint.path(base, owner)) do
      {seq, records} = if checkpoint, do: {checkpoint.seq, checkpoint.records}, else: {0, %{}}

      frames = Enum.sort(for {^owner, s, frame} <- log_frames(base), s > seq, do: {s, frame})
      {:ok, frames |> List.last({seq, nil}) |> elem(0), fold(records, ops(frames))}
    end
  end

  defp log_frames(base) do
    for n <- 0..(Log.stripes() - 1),
        dir = Log.dir(base, n),
        File.dir?(dir),
        {:ok, %{frames: frames}} <- [Valimc.Storage.RegionLog.read(dir)],
        %{ops: ops} <- frames,
        {:frame, owner, s, frame} <- ops,
        do: {owner, s, frame}
  end

  @doc "A region's export-only imported data (`chunk_extras`, `entities`), offline."
  def extra(base, dimension, key) do
    path = Checkpoint.extra(Checkpoint.path(base, {:region, dimension, key}))

    stored =
      case File.read(path) do
        {:ok, bytes} -> :erlang.binary_to_term(bytes, [:safe])
        {:error, :enoent} -> %{}
      end

    Map.merge(%{chunk_extras: %{}, entities: []}, stored)
  end
end
