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
  | `{:receipt, source}` | a player transfer's receipt |
  | `{:handoff, field}`, `{:handoff_in, source}` | the entity handoff ledger: sequence, outgoing intent, incoming receipts |
  | `{:container, position}`, `{:container_receipt, source}`, `{:containers, field}` | containers |
  | `{:tick, position, block}` | a scheduled block tick, `{due, priority}` |
  | `{:block_entity, position}` | a preserved block entity, `{type, nbt}` |
  | `:game_tick` | the region's game tick when the frame was cut |

  The owner adopts every change in memory at once and replies at once (D2).
  Every 50 ms (`@commit_ms`) the changes since the last frame are one frame:
  cells and columns as they were made, every other part as the difference of
  its keyed records from the last frame's. Only the replies of cross-owner
  transfer steps wait for their frame to be durable (`after_durable/2`), so
  a crash can lose the last frames but never one half of a transfer.

  Item motion (position, velocity) goes into a frame at most once a second.
  Counters that move every tick (an item's age and delays, a furnace's
  remaining burn and progress) stay out of frames unless they cross zero; a
  checkpoint saves them, at the latest five minutes after they moved, like
  vanilla's autosave. A crash can roll back only motion and counters.

  A checkpoint holds every record with cells folded into column images taken
  from the owner's Rust blocks (relit alone, VMC-077c) and replaces the file;
  the log then forgets the frames it holds. Checkpoints follow appended bytes,
  frame count, moved counters, `/save-all` and unload; `/save-off` pauses
  them, not the log. A world without a path keeps everything in memory.
  """
  require Logger
  alias Valimc.Storage.{Checkpoint, Log}
  alias Valimc.World.{BlockEntities, Blocks, Containers, Entities, ScheduledTicks}

  @commit_ms 50
  @checkpoint_bytes 1024 * 1024
  @checkpoint_frames 1200
  # Vanilla autosaves every 6000 ticks.
  @autosave_ms 300_000
  # Item motion is written at most this often, like the item checkpoints before.
  @motion_ms 1000
  @parts [:items, :receipts, :containers, :ticks, :block_entities]
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
    dirty_chunks: MapSet.new(),
    checkpoint_seq: 0,
    since_checkpoint: 0,
    frames_since_checkpoint: 0,
    checkpointing: nil,
    requested: false,
    counters_since: nil,
    motion_waiting: false,
    motion_at: 0,
    # {pid, monitor} of the log stripe the owner commits to
    stripe: nil
  ]

  def commit_ms, do: @commit_ms

  @doc """
  Open the storage of region `key` in the caller's dimension: its checkpoint
  and the frames after it. `{:ok, storage, loaded}` with the region's parts, or
  `{:error, reason}`; a region stored before VMC-077f is refused (D4).
  """
  def open(key) do
    dimension = Valimc.Dimension.current()
    base = Valimc.config(:world_path, key)
    owner = {:region, dimension, key}

    if base == nil do
      {:ok, %__MODULE__{owner: owner}, restore(%{}, false)}
    else
      path = Checkpoint.path(base, owner)

      with :ok <- current_format(path, key),
           {:ok, checkpoint} <- Checkpoint.read(path),
           {seq, records} =
             if(checkpoint, do: {checkpoint.seq, checkpoint.records}, else: {0, %{}}),
           frames when is_list(frames) <- Log.frames(base, owner, seq) do
        {records, last} =
          Enum.reduce(frames, {records, seq}, fn {seq, frame}, {acc, _} ->
            {apply_ops(acc, :erlang.binary_to_term(frame, [:safe])), seq}
          end)

        storage = %__MODULE__{
          base: base,
          owner: owner,
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
      Enum.reduce(columns, storage.pending, fn {chunk, image}, acc ->
        acc
        |> Map.reject(fn {key, _} -> match?({:cell, _}, key) and cell_chunk(key) == chunk end)
        |> Map.put({:column, chunk}, image)
      end)

    %{storage | pending: pending}
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
  reply}` or `{:effect, term}` (returned by `durable/2`). Only cross-owner
  transfer steps need this.
  """
  def after_durable(storage, item), do: %{storage | waits: storage.waits ++ [item]}

  @doc "Whether frames or waits are outstanding (an owner with them does not unload)."
  def busy?(storage),
    do: map_size(storage.in_flight) > 0 or storage.waits != [] or storage.checkpointing != nil

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

  # One frame, or several below the cap when one tick changed very much.
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
      stripe = Log.commit(acc.base, acc.owner, acc.seq + 1, frame, self())
      {%{acc | seq: acc.seq + 1, stripe: watch(acc.stripe, stripe)}, bytes + byte_size(frame)}
    end)
  end

  defp watch({pid, _} = watched, pid), do: watched

  defp watch(watched, pid) do
    with {_, ref} <- watched, do: Process.demonitor(ref, [:flush])
    {pid, Process.monitor(pid)}
  end

  @doc """
  The owner's stripe (monitored as `ref`) went down: `{:failed, storage}` when
  frames were in flight on it (they may or may not be durable, so the owner
  stops and reloads), `{:ok, storage}` otherwise.
  """
  def stripe_down(%{stripe: {_, ref}} = storage, ref) do
    storage = %{storage | stripe: nil}
    if map_size(storage.in_flight) > 0, do: {:failed, storage}, else: {:ok, storage}
  end

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
  appended (a checkpoint reads them back), and saving not paused.
  """
  def checkpoint_due?(storage) do
    storage.base != nil and storage.checkpointing == nil and map_size(storage.pending) == 0 and
      map_size(storage.in_flight) == 0 and Valimc.World.Saving.auto?() and
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
  `{:checkpointed, ref, seq, result}` to the owner. `sync: true` writes it here.
  """
  def checkpoint(storage, parts, blocks, opts \\ []) do
    chunks = storage.dirty_chunks

    job = %{
      base: storage.base,
      owner: storage.owner,
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
      sky: Valimc.Dimension.facts().sky_light
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

    if opts[:sync] do
      covered(storage, chunks, job.seq, write_checkpoint(job))
    else
      owner = self()
      ref = make_ref()

      {:ok, _} =
        Task.start(
          Valimc.Dimension.bind(fn ->
            send(owner, {:checkpointed, ref, job.seq, write_checkpoint(job)})
          end)
        )

      %{storage | checkpointing: {ref, chunks}}
    end
  end

  @doc "A checkpoint task finished."
  def checkpointed(%{checkpointing: {ref, chunks}} = storage, ref, seq, result),
    do: covered(%{storage | checkpointing: nil}, chunks, seq, result)

  def checkpointed(storage, _ref, _seq, _result), do: storage

  defp covered(storage, _chunks, seq, :ok) do
    Log.covered(storage.base, storage.owner, seq)
    Valimc.Metrics.add(:region_checkpoints)

    %{
      storage
      | checkpoint_seq: seq,
        since_checkpoint: 0,
        frames_since_checkpoint: storage.seq - seq
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
  defp write_checkpoint(job) do
    with {:ok, previous} <- Checkpoint.read(job.path),
         {seq, records} = if(previous, do: {previous.seq, previous.records}, else: {0, %{}}),
         frames when is_list(frames) <- Log.frames(job.base, job.owner, seq) do
      durable =
        for {s, frame} <- frames, s <= job.seq, reduce: records do
          acc -> apply_ops(acc, :erlang.binary_to_term(frame, [:safe]))
        end

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

  ## Parts and records

  @doc """
  The owner's keyed parts for commits and checkpoints: `items` (an
  `Valimc.World.Entities`), `receipts`, `containers`, `ticks` (a
  `ScheduledTicks`), `block_entities` and `game_tick`.
  """
  def diff_parts(storage, parts) do
    now = System.monotonic_time(:millisecond)
    full = storage.motion_waiting and now >= storage.motion_at

    storage =
      Enum.reduce(@parts, %{storage | motion_waiting: storage.motion_waiting and not full}, fn
        part, acc ->
          value = Map.fetch!(parts, part)

          case acc.committed do
            %{^part => {^value, _}} when not full ->
              acc

            committed ->
              previous = with {_, records} <- committed[part], do: records

              {pending, written, waits} =
                diff(acc.pending, previous || %{}, part_records(part, value), full)

              %{
                acc
                | pending: pending,
                  committed: Map.put(committed, part, {value, written}),
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

  @doc "Take `parts` as what the log and checkpoint hold (after a load or a checkpoint)."
  def baseline(storage, parts) do
    committed =
      Map.new(@parts, fn part ->
        {part, {Map.fetch!(parts, part), part_records(part, Map.fetch!(parts, part))}}
      end)

    %{
      storage
      | committed: committed,
        motion_waiting: false,
        motion_at: System.monotonic_time(:millisecond) + @motion_ms
    }
  end

  # `{pending, written, waits}`: changed records the next frame must carry go
  # to `pending`; a record whose change may wait keeps its last written value
  # in `written`, and `waits` says what waits (`:motion`, `:counters`).
  defp diff(pending, previous, current, full) do
    {pending, written, waits} =
      Enum.reduce(current, {pending, current, []}, fn {key, value}, {acc, written, waits} ->
        case previous do
          %{^key => ^value} ->
            {acc, written, waits}

          %{^key => old} ->
            case wait(key, old, value, full) do
              nil -> {Map.put(acc, key, value), written, waits}
              kind -> {acc, Map.put(written, key, old), [kind | waits]}
            end

          _ ->
            {Map.put(acc, key, value), written, waits}
        end
      end)

    pending =
      Enum.reduce(previous, pending, fn {key, _}, acc ->
        if Map.has_key?(current, key), do: acc, else: Map.put(acc, key, :deleted)
      end)

    {pending, written, Enum.uniq(waits)}
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
  def part_records(:items, %Entities{} = items) do
    ledger = items.ledger

    for(record <- Entities.records(items), into: %{}, do: {{:entity, record.uuid}, record})
    |> Map.merge(%{
      {:handoff, :sequence} => ledger.sequence,
      {:handoff, :outgoing} => stored_outgoing(ledger.outgoing)
    })
    |> Map.merge(
      for {source, receipt} <- ledger.incoming, into: %{}, do: {{:handoff_in, source}, receipt}
    )
  end

  def part_records(:receipts, receipts),
    do: for({source, receipt} <- receipts, into: %{}, do: {{:receipt, source}, receipt})

  def part_records(:containers, %Containers{} = c) do
    fields =
      Map.take(c, [
        :sequence,
        :pending_awards,
        :cooking_orbs,
        :orb_transfers,
        :orb_consumption,
        :orb_bodies
      ])

    for(
      field <- Map.to_list(fields),
      into: %{},
      do: {{:containers, elem(field, 0)}, elem(field, 1)}
    )
    |> Map.merge(for {pos, entry} <- c.entries, into: %{}, do: {{:container, pos}, entry})
    |> Map.merge(
      for {source, receipt} <- c.receipts, into: %{}, do: {{:container_receipt, source}, receipt}
    )
  end

  def part_records(:ticks, %ScheduledTicks{index: index}),
    do:
      for(
        {{pos, block}, {due, priority, _, _, _}} <- index,
        into: %{},
        do: {{:tick, pos, block}, {due, priority}}
      )

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
  def apply_ops(records, ops) do
    Enum.reduce(ops, records, fn
      {:put, {:column, chunk} = key, image}, acc ->
        acc
        |> Map.reject(fn {k, _} -> match?({:cell, _}, k) and cell_chunk(k) == chunk end)
        |> Map.put(key, image)

      {:put, key, value}, acc ->
        Map.put(acc, key, value)

      {:del, key}, acc ->
        Map.delete(acc, key)
    end)
  end

  # The region's parts from its records.
  defp restore(records, persistent) do
    empty = %{
      columns: %{},
      cells: %{},
      post_processing: %{},
      items: [],
      receipts: %{},
      ledger: Entities.empty_ledger(),
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

      {{:receipt, source}, receipt}, acc ->
        put_in(acc, [:receipts, source], receipt)

      {{:handoff, field}, value}, acc when field in [:sequence, :outgoing] ->
        %{acc | ledger: Map.put(acc.ledger, field, value)}

      {{:handoff_in, source}, receipt}, acc ->
        %{acc | ledger: %{acc.ledger | incoming: Map.put(acc.ledger.incoming, source, receipt)}}

      {{:container, pos}, entry}, acc ->
        %{
          acc
          | containers: %{acc.containers | entries: Map.put(acc.containers.entries, pos, entry)}
        }

      {{:container_receipt, source}, receipt}, acc ->
        %{
          acc
          | containers: %{
              acc.containers
              | receipts: Map.put(acc.containers.receipts, source, receipt)
            }
        }

      {{:containers, field}, value}, acc ->
        %{acc | containers: Map.put(acc.containers, field, value)}

      {{:tick, pos, block}, {due, priority}}, acc ->
        %{acc | ticks: [{pos, block, due, priority} | acc.ticks]}

      {{:block_entity, pos}, value}, acc ->
        put_in(acc, [:block_entities, pos], value)

      {:game_tick, _}, acc ->
        acc

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
                   Valimc.DurableFile.write(Checkpoint.extra(path), :erlang.term_to_binary(extra))
               )
    end
  end

  @doc """
  The regions of `dimension` stored under `base`, offline: checkpoint files
  and regions the log holds frames of. A world stored before VMC-077f is refused.
  """
  def keys(base, dimension) do
    dir = Valimc.Dimension.storage(base, dimension)

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

      for({^owner, s, frame} <- log_frames(base), s > seq, do: {s, frame})
      |> Enum.sort()
      |> Enum.reduce({:ok, seq, records}, fn {s, frame}, {:ok, _, acc} ->
        {:ok, s, apply_ops(acc, :erlang.binary_to_term(frame, [:safe]))}
      end)
    end
  end

  defp log_frames(base) do
    for n <- 0..(Log.stripes() - 1),
        dir = Log.dir(base, n),
        File.dir?(dir),
        {:ok, %{frames: frames}} <- [Valimc.World.RegionLog.read(dir)],
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
