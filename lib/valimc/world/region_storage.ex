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
  | `{:post, chunk}` | what a generated chunk leaves for fluids |
  | `{:entity, uuid}` | an entity's record (an item, an orb) |
  | `{:handoff, field}`, `{:handoff_in, source}` | the entity handoff ledger: sequence, outgoing intent, incoming receipts |
  | `{:container, position}`, `{:containers, :sequence}` | containers |
  | `{:ticks, chunk}`, `{:ticks, :shift}` | a chunk's scheduled block ticks in order, `[{due, priority, position, block}]`, dues relative to the shift |
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
  durable together. A section that moved to a group on another stripe sends
  there only once its frames on the old stripe are durable (`held?/2`).

  Item motion (position, velocity) goes into a frame at most once a second.
  Counters that move every tick (an item's age and delays, a furnace's
  remaining burn and progress) stay out of frames unless they cross zero; a
  checkpoint saves them, at the latest five minutes after they moved, like
  vanilla's autosave. A crash can roll back only motion and counters.

  A checkpoint holds every record with cells folded into column images taken
  from the owner's Rust blocks (relit alone, VMC-077c) and replaces the file;
  the log then forgets the frames it holds. The section keeps its frames since
  its last checkpoint (up to #{64} MiB; past that the checkpoint reads them
  from the log), so a checkpoint folds them without the log rereading its
  segments. An unloading section's checkpoint is written off its group; the
  writes of one file never overlap, and a section loading again waits for
  the one in progress. Checkpoints follow appended bytes,
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
  @parts [:items, :containers, :ticks, :block_entities]
  # Owner frames stay well below the log's frame cap (world-core E1).
  @frame_bytes 8 * 1024 * 1024
  # Frames kept for the next checkpoint (`/save-off` pauses checkpoints).
  @kept_bytes 64 * 1024 * 1024

  defstruct [
    :base,
    :owner,
    :path,
    seq: 0,
    pending: %{},
    waits: [],
    in_flight: %{},
    committed: %{},
    # The last written records of changes that wait (`diff_parts/2`).
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
    # Every frame since the checkpoint (`[{seq, frame}]`, newest first), or
    # `:log` once they passed `@kept_bytes`; `kept_bytes` their size.
    kept: [],
    kept_bytes: 0,
    # The key whose stripe the section's group commits to, and the route of
    # each frame in flight.
    route: nil,
    routes: %{}
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
        records = fold(records, frames)
        last = frames |> List.last({seq, nil}) |> elem(0)

        storage =
          keep(
            %__MODULE__{
              base: base,
              owner: owner,
              route: owner,
              path: path,
              seq: last,
              checkpoint_seq: seq,
              frames_since_checkpoint: last - seq
            },
            frames
          )

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

  @doc "Generated chunks' post-processing (`chunk => value`)."
  def post_processing(storage, chunks),
    do: %{
      storage
      | pending:
          Enum.reduce(chunks, storage.pending, fn {c, v}, acc -> Map.put(acc, {:post, c}, v) end)
    }

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

      acc =
        keep(%{acc | seq: seq, outbox: [{acc.owner, seq, frame} | acc.outbox]}, [{seq, frame}])

      {acc, bytes + byte_size(frame)}
    end)
  end

  # Frames (`[{seq, frame}]`, oldest first) the next checkpoint folds.
  defp keep(%{kept: :log} = storage, _frames), do: storage

  defp keep(storage, frames) do
    bytes = Enum.reduce(frames, storage.kept_bytes, &(byte_size(elem(&1, 1)) + &2))

    if bytes > @kept_bytes,
      do: %{storage | kept: :log, kept_bytes: 0},
      else: %{storage | kept: Enum.reverse(frames, storage.kept), kept_bytes: bytes}
  end

  @doc """
  The outbox's frames, oldest first, to send on `route`'s stripe, and the
  storage that has sent them.
  """
  def take(%{outbox: []} = storage, _route), do: {[], storage}

  def take(storage, route) do
    frames = Enum.reverse(storage.outbox)

    routes =
      Enum.reduce(frames, storage.routes, fn {_, seq, _}, acc -> Map.put(acc, seq, route) end)

    {frames, %{storage | outbox: [], routes: routes}}
  end

  @doc """
  Whether the section must not send on `route` yet: frames of it are in
  flight on another stripe, and a later one there could be durable first.
  """
  def held?(storage, route) do
    stripe = Log.stripe(route)
    Enum.any?(storage.routes, fn {_, r} -> Log.stripe(r) != stripe end)
  end

  @doc "Send the outbox now, on the section's own route, and wait until it is appended."
  def send_now(storage, sync \\ true)
  def send_now(%{base: nil} = storage, _sync), do: storage

  def send_now(storage, sync) do
    {frames, storage} = take(storage, storage.route)
    if frames != [], do: Log.commit_group(storage.base, storage.route, frames, self())

    if sync,
      do:
        for(
          route <- Enum.uniq([storage.route | Map.values(storage.routes)]),
          do: :ok = Log.sync(storage.base, route)
        )

    storage
  end

  @doc """
  Whether a reply waits on a frame (an entity handoff's): a section that
  unloads with none needs no wait for its last frames, whose checkpoint
  holds them (`checkpoint/4` with `detach: true`).
  """
  def waiting?(storage),
    do: storage.waits != [] or Enum.any?(storage.in_flight, fn {_, waits} -> waits != [] end)

  @doc "A frame is durable: `{storage, items}` its waits (and earlier ones) to run."
  def durable(storage, seq) do
    {done, in_flight} = Map.split_with(storage.in_flight, fn {s, _} -> s <= seq end)
    items = done |> Enum.sort() |> Enum.flat_map(&elem(&1, 1))
    routes = Map.reject(storage.routes, fn {s, _} -> s <= seq end)
    {%{storage | in_flight: in_flight, routes: routes}, items}
  end

  ## Checkpoints

  @doc "Ask for a checkpoint as soon as one may run (`/save-all`)."
  def request_checkpoint(storage), do: %{storage | requested: true}

  @doc """
  Whether a checkpoint is due: requested, enough bytes or frames since the last
  one, or counters moved five minutes ago; none running, every frame cut and
  appended (a checkpoint reads them back), and saving not paused.
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
  Start a checkpoint of `parts` (the owner's current parts, everything cut into
  frames up to `storage.seq`) and `blocks`; a task merges the images of the
  dirty chunks into the last checkpoint's and writes the file, then sends
  `{:checkpointed, ref, seq, result}` to the owner. `sync: true` writes it
  here; `detach: true` (an unloading section) leaves it to the task, which
  reports what it covers to the log itself.
  """
  def checkpoint(storage, parts, blocks, opts \\ []) do
    chunks = storage.dirty_chunks

    job = %{
      base: storage.base,
      owner: storage.owner,
      path: storage.path,
      seq: storage.seq,
      kept: storage.kept,
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

    storage =
      %{
        baseline(storage, parts)
        | dirty_chunks: MapSet.new(),
          requested: false,
          counters_since: nil
      }

    cond do
      opts[:sync] ->
        covered(storage, chunks, job.seq, write_checkpoint(job))

      # The task holds the file before the section's route goes: a load
      # after that waits for it (`await_checkpoint/1`).
      opts[:detach] ->
        parent = self()
        tag = make_ref()
        routes = Enum.uniq([storage.route | Map.values(storage.routes)])

        {:ok, _} =
          Task.start(
            Valimc.World.Dimension.bind(fn ->
              locked(job.path, fn ->
                send(parent, {tag, :locked})

                case fold_checkpoint(job) do
                  # The log may still be appending the last frames: it learns
                  # they are covered once it holds them.
                  :ok ->
                    for route <- routes, do: :ok = Log.sync(job.base, route)
                    Log.covered(job.base, job.owner, job.seq)

                  {:error, reason} ->
                    Logger.error("Region checkpoint failed: #{inspect(reason)}")
                end
              end)
            end)
          )

        receive do
          {^tag, :locked} -> storage
        end

      true ->
        async_checkpoint(storage, job, chunks)
    end
  end

  defp async_checkpoint(storage, job, chunks) do
    owner = self()
    ref = make_ref()

    {:ok, _} =
      Task.start(
        Valimc.World.Dimension.bind(fn ->
          send(owner, {:checkpointed, ref, job.seq, write_checkpoint(job)})
        end)
      )

    %{storage | checkpointing: {ref, chunks}}
  end

  @doc "A checkpoint task finished."
  def checkpointed(%{checkpointing: {ref, chunks}} = storage, ref, seq, result),
    do: covered(%{storage | checkpointing: nil}, chunks, seq, result)

  def checkpointed(storage, _ref, _seq, _result), do: storage

  defp covered(storage, _chunks, seq, :ok) do
    Log.covered(storage.base, storage.owner, seq)
    Valimc.Data.Metrics.add(:region_checkpoints)

    kept =
      cond do
        storage.kept != :log -> Enum.take_while(storage.kept, fn {s, _} -> s > seq end)
        seq == storage.seq -> []
        true -> :log
      end

    %{
      storage
      | checkpoint_seq: seq,
        since_checkpoint: 0,
        frames_since_checkpoint: storage.seq - seq,
        kept: kept,
        kept_bytes:
          if(kept == :log, do: 0, else: Enum.reduce(kept, 0, &(byte_size(elem(&1, 1)) + &2)))
    }
  end

  # A failed checkpoint leaves the log (only waiting motion and counters are
  # lost); its chunks stay dirty for the next one.
  defp covered(storage, chunks, _seq, {:error, reason}) do
    Logger.error("Region checkpoint failed: #{inspect(reason)}")
    %{storage | dirty_chunks: MapSet.union(storage.dirty_chunks, chunks)}
  end

  # The durable records through `seq` (the last checkpoint and the frames
  # after it), with the owner's parts as they were at `seq` and the dirty
  # chunks' images, relit alone, in place of their cells.
  defp write_checkpoint(job), do: locked(job.path, fn -> fold_checkpoint(job) end)

  defp fold_checkpoint(job) do
    with {:ok, previous} <- Checkpoint.read(job.path),
         {seq, records} = if(previous, do: {previous.seq, previous.records}, else: {0, %{}}),
         frames when is_list(frames) <- since(job, seq) do
      durable = fold(records, Enum.filter(frames, &(elem(&1, 0) <= job.seq)))

      kept =
        Map.filter(durable, fn {key, _} ->
          match?({:column, _}, key) or match?({:post, _}, key)
        end)

      lit = Blocks.lit_images(job.images, job.sky)
      columns = for {chunk, image} <- lit, into: %{}, do: {{:column, chunk}, image}
      Checkpoint.write(job.path, job.seq, kept |> Map.merge(columns) |> Map.merge(job.records))
    end
  rescue
    error -> {:error, Exception.message(error)}
  end

  # The frames after `seq`, oldest first: those the section kept, or the log's.
  defp since(%{kept: :log} = job, seq), do: Log.frames(job.base, job.owner, seq)
  defp since(job, seq), do: job.kept |> Enum.filter(&(elem(&1, 0) > seq)) |> Enum.reverse()

  # One checkpoint write of a file at a time: an unloading section's may
  # still run when it loads again.
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
        after
          100 ->
            Process.demonitor(ref, [:flush])
            await_checkpoint(path)
        end
    end
  end

  ## Parts and records

  @doc """
  The owner's keyed parts for commits and checkpoints: `items` (an
  `Valimc.Entity.Store`), `containers`, `ticks` (a
  `ScheduledTicks`), `block_entities` and `game_tick`.

  A frame carries only what changed, found in O(changes): the scheduled
  ticks' journal (`ScheduledTicks.changes/1`) and, for the keyed maps of the
  other parts, the entries that are no longer the ones last committed (an
  unchanged entry is the same term and compares at once). A change that may
  wait (`wait/4`) keeps its last written record in `deferred` until it
  changes otherwise, or until the next motion pass writes it.
  """
  def diff_parts(storage, parts) do
    now = System.monotonic_time(:millisecond)
    full = storage.motion_waiting and now >= storage.motion_at

    storage =
      Enum.reduce(@parts, %{storage | motion_waiting: storage.motion_waiting and not full}, fn
        part, acc ->
          value = Map.fetch!(parts, part)

          case acc.committed do
            %{^part => ^value} when not full ->
              acc

            committed ->
              changes = changes(part, Map.get(committed, part), value)
              changes = if full, do: flush(acc.deferred, part, value, changes), else: changes
              {pending, deferred, waits} = settle(acc.pending, acc.deferred, changes, full)

              %{
                acc
                | pending: pending,
                  deferred: deferred,
                  committed: Map.put(committed, part, value),
                  motion_waiting: acc.motion_waiting or :motion in waits,
                  counters_since:
                    if(:counters in waits and acc.counters_since == nil,
                      do: now,
                      else: acc.counters_since
                    )
              }
          end
      end)

    storage = if full, do: %{storage | motion_at: now + @motion_ms}, else: storage

    if map_size(storage.pending) > 0,
      do: %{storage | pending: Map.put(storage.pending, :game_tick, parts.game_tick)},
      else: storage
  end

  @doc """
  Take `parts` as what the log and checkpoint hold (after a load or a
  checkpoint); the owner then settles its scheduled ticks' journal.
  """
  def baseline(storage, parts) do
    %{
      storage
      | committed: Map.new(@parts, &{&1, Map.fetch!(parts, &1)}),
        deferred: %{},
        motion_waiting: false,
        motion_at: System.monotonic_time(:millisecond) + @motion_ms
    }
  end

  # `%{key => {old, new}}` of the records that changed between the last
  # committed value of `part` and `value` (`new` is `:deleted` for a gone
  # record; `old` nil for a new one, `:unknown` where the part keeps no old).
  defp changes(:ticks, previous, ticks) do
    changes = ScheduledTicks.changes(ticks)

    changes =
      if match?(%ScheduledTicks{}, previous) and previous.shift == ticks.shift,
        do: Map.delete(changes, {:ticks, :shift}),
        else: changes

    Map.new(changes, fn {key, value} -> {key, {:unknown, value}} end)
  end

  defp changes(:items, previous, %Store{} = items) do
    old = if previous, do: previous.entries, else: %{}

    entities =
      keyed_changes(old, items.entries, fn _id, entry ->
        {{:entity, entry.entity.uuid}, Store.record(entry)}
      end)

    old_ledger = if previous, do: ledger_records(previous.ledger), else: %{}
    map_changes(old_ledger, ledger_records(items.ledger), entities)
  end

  defp changes(:containers, previous, %Containers{} = c) do
    old = if previous, do: previous.entries, else: %{}
    changes = keyed_changes(old, c.entries, fn pos, entry -> {{:container, pos}, entry} end)

    if previous && previous.sequence == c.sequence,
      do: changes,
      else:
        Map.put(changes, {:containers, :sequence}, {previous && previous.sequence, c.sequence})
  end

  defp changes(:block_entities, previous, %BlockEntities{entries: entries}) do
    old = if previous, do: previous.entries, else: %{}

    keyed_changes(old, entries, fn pos, %{type: type, nbt: nbt} ->
      {{:block_entity, pos}, {type, nbt}}
    end)
  end

  # The records of the entries of `new` that are not the entries of `old`,
  # and of those gone; `record` maps a key and entry to `{record key, record}`.
  defp keyed_changes(old, new, _record) when old === new, do: %{}

  defp keyed_changes(old, new, record) do
    changed =
      Enum.reduce(new, %{}, fn {key, entry}, acc ->
        case old do
          %{^key => ^entry} ->
            acc

          %{^key => before} ->
            {record_key, after_record} = record.(key, entry)
            {_, before_record} = record.(key, before)
            Map.put(acc, record_key, {before_record, after_record})

          _ ->
            {record_key, after_record} = record.(key, entry)
            Map.put(acc, record_key, {nil, after_record})
        end
      end)

    Enum.reduce(old, changed, fn {key, before}, acc ->
      if Map.has_key?(new, key) do
        acc
      else
        {record_key, before_record} = record.(key, before)
        Map.put(acc, record_key, {before_record, :deleted})
      end
    end)
  end

  defp map_changes(old, new, acc) do
    acc =
      Enum.reduce(new, acc, fn {key, value}, acc ->
        case old do
          %{^key => ^value} -> acc
          _ -> Map.put(acc, key, {Map.get(old, key), value})
        end
      end)

    Enum.reduce(old, acc, fn {key, value}, acc ->
      if Map.has_key?(new, key), do: acc, else: Map.put(acc, key, {value, :deleted})
    end)
  end

  defp ledger_records(ledger) do
    %{
      {:handoff, :sequence} => ledger.sequence,
      {:handoff, :outgoing} => stored_outgoing(ledger.outgoing)
    }
    |> Map.merge(
      for {source, receipt} <- ledger.incoming, into: %{}, do: {{:handoff_in, source}, receipt}
    )
  end

  # A motion pass writes what waited: each deferred record of `part` that has
  # not changed again since.
  defp flush(deferred, part, value, changes) do
    Enum.reduce(deferred, changes, fn {key, written}, acc ->
      if Map.has_key?(acc, key) or part_of(key) != part,
        do: acc,
        else: Map.put(acc, key, {written, current(part, value, key)})
    end)
  end

  defp part_of({:entity, _}), do: :items
  defp part_of({:container, _}), do: :containers
  defp part_of(_), do: nil

  defp current(:items, %Store{} = items, {:entity, uuid}) do
    case items.uuids do
      %{^uuid => id} -> Store.record(items.entries[id])
      _ -> :deleted
    end
  end

  defp current(:containers, %Containers{entries: entries}, {:container, pos}),
    do: Map.get(entries, pos, :deleted)

  # `{pending, deferred, waits}`: changed records the next frame must carry go
  # to `pending`; one whose change may wait keeps its last written record in
  # `deferred`, and `waits` says what waits (`:motion`, `:counters`).
  defp settle(pending, deferred, changes, full) do
    {pending, deferred, waits} =
      Enum.reduce(changes, {pending, deferred, []}, fn {key, {before, value}},
                                                       {pending, deferred, waits} ->
        written = Map.get(deferred, key, before)

        cond do
          # Back to what the last frame wrote while it waited: nothing to write.
          value == written and is_map_key(deferred, key) ->
            {Map.delete(pending, key), Map.delete(deferred, key), waits}

          value == written ->
            {pending, deferred, waits}

          value == :deleted or written in [nil, :unknown, :deleted] ->
            {Map.put(pending, key, value), Map.delete(deferred, key), waits}

          true ->
            case wait(key, written, value, full) do
              nil ->
                {Map.put(pending, key, value), Map.delete(deferred, key), waits}

              kind ->
                {pending, Map.put_new(deferred, key, written), [kind | waits]}
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

  defp wait({:container, _}, %{cooking: %{} = a} = old, %{cooking: %{} = b} = new, _full),
    do: if(%{old | cooking: burning(a)} == %{new | cooking: burning(b)}, do: :counters)

  defp wait(_key, _old, _new, _full), do: nil

  defp counters(%{motion: motion} = record),
    do: %{record | motion: %{motion | age: 0, pickup_delay: 0, portal_cooldown: 0}}

  defp moved(record) do
    %{motion: motion} = record = counters(record)
    %{record | x: 0, y: 0, z: 0, motion: %{motion | velocity: nil, on_ground: nil}}
  end

  # Burning out or finishing is a change; burning on is not.
  defp burning(cooking),
    do: %{cooking | burn_left: cooking.burn_left > 0, progress: cooking.progress > 0}

  defp records(parts) do
    Enum.reduce(@parts, %{}, fn part, acc ->
      Map.merge(acc, part_records(part, Map.fetch!(parts, part)))
    end)
  end

  @doc false
  def part_records(:items, %Store{} = items) do
    for(record <- Store.records(items), into: %{}, do: {{:entity, record.uuid}, record})
    |> Map.merge(ledger_records(items.ledger))
  end

  def part_records(:containers, %Containers{} = c) do
    %{{:containers, :sequence} => c.sequence}
    |> Map.merge(for {pos, entry} <- c.entries, into: %{}, do: {{:container, pos}, entry})
  end

  def part_records(:ticks, %ScheduledTicks{} = ticks), do: ScheduledTicks.records(ticks)

  def part_records(:block_entities, %BlockEntities{entries: entries}),
    do:
      for(
        {pos, %{type: type, nbt: nbt}} <- entries,
        into: %{},
        do: {{:block_entity, pos}, {type, nbt}}
      )

  # Network ids are the VM's: a recovered intent delivers without them.
  defp stored_outgoing(nil), do: nil

  defp stored_outgoing(outgoing),
    do: %{outgoing | records: Enum.map(outgoing.records, &Map.delete(&1, :entity_id))}

  @doc false
  def apply_ops(records, ops), do: fold(records, [{nil, :erlang.term_to_binary(ops)}])

  # Records with `frames` (`[{seq, frame}]`, in order) applied. A frame's
  # column image replaces its chunk's earlier cells, and holds no cell of a
  # chunk it puts a column of (`columns/2`): the cells are kept apart, so a
  # column drops them without passing over every other record.
  defp fold(records, []), do: records

  defp fold(records, frames) do
    {cells, rest} = Map.split_with(records, fn {key, _} -> match?({:cell, _}, key) end)

    {cells, rest} =
      Enum.reduce(frames, {cells, rest}, fn {_, frame}, {cells, rest} ->
        ops = :erlang.binary_to_term(frame, [:safe])
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

  # The region's parts from its records.
  defp restore(records, persistent) do
    empty = %{
      columns: %{},
      cells: %{},
      post_processing: %{},
      items: [],
      ledger: Store.empty_ledger(),
      containers: %Containers{},
      ticks: [],
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

      {{:entity, _}, record}, acc ->
        %{acc | items: [record | acc.items]}

      {{:handoff, field}, value}, acc when field in [:sequence, :outgoing] ->
        %{acc | ledger: Map.put(acc.ledger, field, value)}

      {{:handoff_in, source}, receipt}, acc ->
        %{acc | ledger: %{acc.ledger | incoming: Map.put(acc.ledger.incoming, source, receipt)}}

      {{:container, pos}, entry}, acc ->
        %{
          acc
          | containers: %{acc.containers | entries: Map.put(acc.containers.entries, pos, entry)}
        }

      {{:containers, :sequence}, value}, acc ->
        %{acc | containers: %{acc.containers | sequence: value}}

      {{:ticks, :shift}, shift}, acc ->
        Map.put(acc, :tick_shift, shift)

      {{:ticks, {_, _}}, list}, acc ->
        %{acc | ticks: [list | acc.ticks]}

      {{:block_entity, pos}, value}, acc ->
        put_in(acc, [:block_entities, pos], value)

      {:game_tick, _}, acc ->
        acc

      # A record of an older format (D4): no migration, no legacy reader.
      {key, _}, _acc ->
        throw({:old_region_format, key})
    end)
    |> Map.update!(:items, &Enum.sort_by(&1, fn r -> r.uuid end))
    |> shift_ticks()
  end

  # Stored dues are relative to the ticks' shift (`ScheduledTicks`).
  defp shift_ticks(parts) do
    {shift, parts} = Map.pop(parts, :tick_shift, 0)

    # In vanilla order across chunks: due, then priority (each chunk's own
    # order is kept).
    %{
      parts
      | ticks:
          for(
            list <- parts.ticks,
            {due, priority, pos, block} <- list,
            do: {pos, block, due + shift, priority}
          )
          |> Enum.sort_by(fn {_, _, due, priority} -> {due, priority} end)
    }
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
      {:ok, frames |> List.last({seq, nil}) |> elem(0), fold(records, frames)}
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
