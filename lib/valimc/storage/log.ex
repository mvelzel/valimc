defmodule Valimc.Storage.Log do
  @moduledoc """
  The world's write-ahead log (VMC-077f): #{8} stripes shared by every owner,
  each a `Valimc.Storage.RegionLog` segment directory `log/wal.<n>/` under the
  world folder, written by one process. An owner always commits to the stripe
  its key hashes to, so its frames stay in order and a crash loses only a
  suffix of them.

  A stripe drains every queued commit into one append with one `datasync`
  (group commit). An append whose segment does not open (out of descriptors)
  wrote nothing; the stripe holds it and everything after it and tries again
  for up to #{30} seconds before failing them. Two kinds of record go in:

  Owner frames are one owner's changes of a tick (a region section,
  `Valimc.World.RegionStorage`, or a player, `Valimc.Player.Storage`), an
  opaque binary of keyed records the owner encodes, numbered per owner
  (`seq`). A group process commits the frames of every section and hosted
  player from one commit as one record (`commit_group/5`, VMC-077j), so a
  crash keeps all of them or none, and the stripe acknowledges the record
  once it is durable. A checkpoint folds an owner's frames (`frames/3`) into
  its file and reports `covered/3` with the last `seq` it holds; a load reads
  the frames after its checkpoint the same way.

  A section's frames go to the stripe of the group it is in, so they may sit
  on several stripes over time: its group sends a frame to a new stripe only
  once those before are durable. An index records the stripes a section has
  sent frames to (the sender writes it before the frame, so a load after a
  crash sees frames still in flight; a recovering stripe writes what it
  finds), and `frames/3` asks only those, so one stalled stripe holds only
  the sections it holds frames of. A stripe keeps, per owner, where each of
  its uncovered frames is (segment, offset, size); `frames/3` reads only
  those bytes, and an owner with none costs a lookup: a load or checkpoint
  never scans the log. A segment is deleted once every frame in it is
  covered.

  On start a stripe reads its segments: owners with frames newer than their
  checkpoint files are admitted (a section) or folded (a player), so they
  replay and checkpoint them. A stripe stops only once its world folder is
  gone (a removed test world): stopping a live one could lose a commit cast
  to it on the way. Worlds written before this log (per-region `r.X.Z/` logs,
  `players/wal.<n>/`) are refused (D4).
  """
  alias Valimc.Data.Grid
  use GenServer, restart: :temporary
  require Logger
  alias Valimc.Storage.Checkpoint
  alias Valimc.Storage.RegionLog

  @stripes 8
  # Sections recovering at once across the stripes, and the counter of them
  # (VMC-081c3).
  @recovery_slots 8
  @recovering {__MODULE__, :recovering}
  @index Valimc.Storage.LogIndex
  @started Valimc.Storage.LogStarted
  @idle_ms 15_000
  @retry_ms 100
  @retries 300
  @max_batch 512
  # Several owner frames share a RegionLog frame up to this many bytes.
  @frame_bytes 16 * 1024 * 1024

  @doc "How many stripes a world's log has."
  def stripes, do: @stripes

  @doc "The stripe of an owner key."
  def stripe(owner), do: :erlang.phash2(owner, @stripes)

  defp region_stripes, do: 0..(@stripes - 1)

  @doc """
  Create the index of the stripes owners' frames are on and the set of worlds
  whose stripes started; the application owns them.
  """
  def init! do
    :ets.new(@index, [:named_table, :public, :set, read_concurrency: true])
    :ets.new(@started, [:named_table, :public, :set])
    :persistent_term.put(@recovering, :atomics.new(1, signed: true))
    :ok
  end

  defp index(base, owner, n) do
    if :ets.whereis(@index) != :undefined, do: :ets.insert(@index, {{base, owner, n}})
    :ok
  end

  defp indexed(base, owner) do
    if :ets.whereis(@index) != :undefined,
      do: Enum.filter(region_stripes(), &:ets.member(@index, {base, owner, &1})),
      else: Enum.to_list(region_stripes())
  end

  # Every stripe of a world recovers (and indexes) its segments when it
  # starts; one with no directory has never held a frame. Once per world.
  defp started(base) do
    if :ets.whereis(@started) == :undefined or :ets.insert_new(@started, {base}),
      do: for(n <- region_stripes(), File.dir?(dir(base, n)), do: ensure_stripe(base, n))

    :ok
  end

  @doc """
  Append `frames` (`[{owner, seq, frame}]`, the owners' frames of one commit)
  as one record on the stripe of `route` (a group's key), so they are durable
  together or not at all; `notify` receives `{:storage_durable, [{owner,
  seq}]}` once for the record (VMC-077w), or `{:storage_failed, owner, seq,
  reason}` for each frame. Returns the stripe for the caller to monitor
  (frames in flight on a stripe that went down may or may not be durable); a
  caller that monitors it already passes it as `stripe` and nothing is
  looked up.
  """
  def commit_group(base, route, frames, notify, stripe \\ nil)
      when is_list(frames) and is_pid(notify) do
    n = stripe(route)
    for {owner, _, _} <- frames, do: index(base, owner, n)
    stripe = if is_pid(stripe), do: stripe, else: ensure_stripe(base, n)
    GenServer.cast(stripe, {:commit, frames, notify})
    stripe
  end

  @doc """
  The frames of `owner` numbered after `seq` that no checkpoint covers, in
  order, as `[{seq, frame}]`, from every region stripe (a section's group
  decides its stripe). The stripes say where they are; the caller reads
  exactly those bytes (`RegionLog.read_at/1`), so a stripe never reads.
  """
  def frames(base, owner, seq) do
    :ok = started(base)

    located =
      for n <- indexed(base, owner),
          entry <- GenServer.call(ensure_stripe(base, n), {:locate, owner, seq}, 60_000),
          do: entry

    seqs = MapSet.new(located, &elem(&1, 0))

    with [_ | _] <- located,
         {:ok, frames} <- RegionLog.read_at(located |> Enum.map(&elem(&1, 1)) |> Enum.uniq()) do
      for(
        %{ops: ops} <- frames,
        {:frame, ^owner, seq, frame} <- ops,
        MapSet.member?(seqs, seq),
        do: {seq, frame}
      )
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.dedup_by(&elem(&1, 0))
    end
  end

  @doc """
  `owner`'s checkpoint holds its frames up to `seq` (on every running region
  stripe; one that is not running reads the checkpoint when it opens).
  """
  def covered(base, owner, seq) do
    for n <- region_stripes(),
        [{pid, _}] <- [Registry.lookup(Valimc.StorageRegistry, {base, n})],
        do: GenServer.cast(pid, {:covered, owner, seq})

    :ok
  end

  @doc "Wait until every commit sent before to `route`'s stripe is appended (durable or failed)."
  def sync(base, route), do: GenServer.call(ensure(base, route), :sync, 60_000)

  @doc "The stripe directory `n` of the world at `base`."
  def dir(base, n), do: Path.join([base, "log", "wal.#{n}"])

  defp ensure(base, owner), do: ensure_stripe(base, stripe(owner))

  defp ensure_stripe(base, n) do
    case Valimc.World.Owners.ensure(
           Valimc.World.Owners.registered(Valimc.StorageRegistry, {base, n}),
           fn ->
             DynamicSupervisor.start_child(Valimc.StorageSupervisor, {__MODULE__, {base, n}})
           end,
           :storage_log_restarting
         ) do
      {:ok, pid} -> pid
      {:error, reason} -> exit({:storage_log_unavailable, reason})
    end
  end

  def start_link({base, n}),
    do:
      GenServer.start_link(__MODULE__, {base, n},
        name: {:via, Registry, {Valimc.StorageRegistry, {base, n}}}
      )

  @impl true
  def init({base, n}) do
    state = %{
      base: base,
      n: n,
      log: nil,
      # owner => queue of {seq, lsn, {segment, offset, size}} of its frames
      # no checkpoint covers yet
      pending: %{},
      # {commits, syncs, attempts} held after an unwritten append
      held: nil,
      # The floor the segments were last pruned to.
      pruned: nil
    }

    case open(state) do
      {:ok, state} -> {:ok, state, @idle_ms}
      {:error, reason} -> {:stop, reason}
    end
  end

  # Open the stripe and recover it: owners' covered frames found from their
  # checkpoint files.
  defp open(state) do
    dir = dir(state.base, state.n)
    old = Path.wildcard(Path.join([state.base, "players", "wal.*"]))

    with :ok <- if(old == [], do: :ok, else: {:error, {:old_player_log, old}}),
         {:ok, log, %{acc: owners}} <- RegionLog.open_fold(dir, %{}, &index_frame/2) do
      pending =
        for {owner, entries} <- owners,
            covered = checkpoint_seq(state.base, owner),
            entries = Enum.filter(Enum.reverse(entries), &(elem(&1, 0) > covered)),
            entries != [],
            into: %{},
            do: {owner, :queue.from_list(entries)}

      # Owners with frames their checkpoint does not cover load, replay and
      # checkpoint them, so the log can be pruned.
      for {owner, _} <- pending, do: index(state.base, owner, state.n)
      for {owner, _} <- pending, do: recover(state.base, owner)
      {:ok, prune(%{state | log: log, pending: pending})}
    end
  rescue
    error in [File.Error, ArgumentError] -> {:error, {:storage_log, Exception.message(error)}}
  end

  # Keep only locations while scanning; retaining decoded payloads here can
  # exhaust a small server before it can reach the checkpoints that cover them.
  defp index_frame(%{lsn: lsn, ops: ops, at: at}, owners) do
    Enum.reduce(ops, owners, fn
      {:frame, owner, seq, _payload}, acc ->
        Map.update(acc, owner, [{seq, lsn, at}], &[{seq, lsn, at} | &1])

      _, acc ->
        acc
    end)
  end

  defp index_frame(_open, owners), do: owners

  defp checkpoint_seq(base, owner) do
    case Checkpoint.seq(Checkpoint.path(base, owner)) do
      {:ok, seq} -> seq
      _ -> -1
    end
  end

  # A section loads whole to replay its frames, so at most #{@recovery_slots}
  # recover at once across the stripes, each until it unloaded again
  # (VMC-081c3): admitting every section a long log names at once took more
  # memory than a small server has, and each restart died recovering again.
  defp recover(_base, {:region, dimension, key}) do
    section = Grid.section(dimension, key, :section)
    Task.start(fn -> with_recovery_slot(fn -> recover_section(section) end) end)
  end

  defp recover(base, {:player, uuid}), do: Valimc.Player.Storage.recover(base, uuid)
  defp recover(_base, _owner), do: :ok

  defp with_recovery_slot(fun) do
    case :persistent_term.get(@recovering, nil) do
      nil ->
        fun.()

      slots ->
        if :atomics.add_get(slots, 1, 1) <= @recovery_slots do
          try do
            fun.()
          after
            :atomics.sub(slots, 1, 1)
          end
        else
          :atomics.sub(slots, 1, 1)
          Process.sleep(100)
          with_recovery_slot(fun)
        end
    end
  end

  # Admitted, it replays and checkpoints; the slot holds until it unloaded,
  # following it into the group it may move to.
  defp recover_section(section) do
    case Valimc.World.Directory.admit(section) do
      {:ok, pid} ->
        await_unloaded(section, pid)

      # The directory or the section is busy: its frames still need it.
      {:error, {:retry, _}} ->
        Process.sleep(1000)
        recover_section(section)

      _ ->
        :ok
    end
  end

  defp await_unloaded(section, pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, _, _} ->
        case Valimc.World.Directory.lookup(section) do
          {next, _, _} when next != pid -> await_unloaded(section, next)
          _ -> :ok
        end
    end
  end

  @impl true
  def handle_cast({:commit, _, _} = first, %{held: nil} = state),
    do: append(state, drain([first], @max_batch - 1), [])

  def handle_cast({:commit, _, _} = commit, %{held: {commits, syncs, n}} = state),
    do: {:noreply, %{state | held: {commits ++ [commit], syncs, n}}, @idle_ms}

  def handle_cast({:covered, owner, seq}, state) do
    pending =
      case state.pending do
        %{^owner => entries} ->
          rest = drop_covered(entries, seq)

          if :queue.is_empty(rest),
            do: Map.delete(state.pending, owner),
            else: Map.put(state.pending, owner, rest)

        pending ->
          pending
      end

    {:noreply, prune(%{state | pending: pending}), @idle_ms}
  end

  defp drop_covered(entries, seq) do
    case :queue.peek(entries) do
      {:value, {s, _, _}} when s <= seq -> drop_covered(:queue.drop(entries), seq)
      _ -> entries
    end
  end

  @impl true
  # Where `owner`'s frames after `after_seq` are, `[{seq, {segment, offset,
  # size}}]`: only frames no checkpoint covers, so a file written anew (a
  # seeded or edited player) does not replay what an earlier checkpoint
  # holds. Their segments stay until a checkpoint covers them.
  def handle_call({:locate, owner, after_seq}, _from, state) do
    located =
      for {seq, _, at} <- :queue.to_list(Map.get(state.pending, owner, :queue.new())),
          seq > after_seq,
          do: {seq, at}

    {:reply, located, state, @idle_ms}
  end

  # Held appends answer once they land or fail.
  def handle_call(:sync, from, %{held: {commits, syncs, n}} = state),
    do: {:noreply, %{state | held: {commits, syncs ++ [from], n}}, @idle_ms}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state, @idle_ms}

  @impl true
  def handle_info(:retry, %{held: {commits, syncs, n}} = state),
    do: append(%{state | held: nil}, commits, syncs, n + 1)

  def handle_info(:timeout, %{held: nil} = state) do
    if File.dir?(state.base, [:raw]) do
      {:noreply, state, @idle_ms}
    else
      if :ets.whereis(@index) != :undefined,
        do:
          (
            :ets.match_delete(@index, {{state.base, :_, state.n}})
            :ets.delete(@started, state.base)
          )

      {:stop, :normal, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state, @idle_ms}

  # Commits from many owners arrive as casts; each owner's stay in order, so
  # taking them ahead of other messages reorders nothing per owner.
  defp drain(commits, 0), do: Enum.reverse(commits)

  defp drain(commits, left) do
    receive do
      {:"$gen_cast", {:commit, _, _} = commit} -> drain([commit | commits], left - 1)
    after
      0 -> Enum.reverse(commits)
    end
  end

  defp append(state, commits, syncs, attempts \\ 0) do
    # A commit's frames stay together in one RegionLog frame (VMC-077j).
    units =
      Enum.map(commits, fn {:commit, frames, _} ->
        for {owner, seq, frame} <- frames, do: {:frame, owner, seq, frame}
      end)

    ops = Enum.concat(units)
    Valimc.Data.Metrics.add(:storage_batches)
    Valimc.Data.Metrics.add(:storage_records, length(ops))
    frames = batches(units)

    with {:ok, state} <- ensure_open(state),
         {:ok, log, located} <- RegionLog.append(state.log, frames) do
      Valimc.Data.Metrics.add(:storage_bytes, Enum.sum(Enum.map(ops, &op_bytes/1)))

      # Each record's lsn and place are its RegionLog frame's.
      lsns = for {frame, place} <- Enum.zip(frames, located), _ <- frame, do: place

      for {:commit, frames, notify} <- commits,
          do: send(notify, {:storage_durable, for({owner, seq, _} <- frames, do: {owner, seq})})

      for from <- syncs, do: GenServer.reply(from, :ok)

      pending =
        commits
        |> Enum.flat_map(fn {:commit, frames, _} ->
          for {owner, seq, _} <- frames, do: {owner, seq}
        end)
        |> Enum.zip(lsns)
        |> Enum.reduce(state.pending, fn {{owner, seq}, {lsn, at}}, acc ->
          entry = {seq, lsn, at}
          Map.update(acc, owner, :queue.from_list([entry]), &:queue.in(entry, &1))
        end)

      {:noreply, %{state | log: log, pending: pending}, @idle_ms}
    else
      # Nothing was written: hold the batch, and what follows, and try again.
      {:error, {:unwritten, _}} when attempts < @retries ->
        Process.send_after(self(), :retry, @retry_ms)
        {:noreply, %{state | held: {commits, syncs, attempts}}, @idle_ms}

      {:error, reason} ->
        Logger.error("Storage log append failed: #{inspect(reason)}")

        for {:commit, frames, notify} <- commits,
            {owner, seq, _} <- frames,
            do: send(notify, {:storage_failed, owner, seq, reason})

        for from <- syncs, do: GenServer.reply(from, :ok)

        # A torn frame may only be repaired by recovery: reopen the stripe.
        case reason do
          {:unwritten, _} -> {:noreply, state, @idle_ms}
          _ -> reopen(state)
        end
    end
  end

  # A stripe whose segments will not open (its folder unwritable) keeps
  # running: the next append opens them again first.
  defp reopen(state) do
    case RegionLog.open(dir(state.base, state.n)) do
      {:ok, log, _} ->
        {:noreply, %{state | log: log}, @idle_ms}

      {:error, reason} ->
        Logger.error("Storage log reopen failed: #{inspect(reason)}")
        {:noreply, %{state | log: nil}, @idle_ms}
    end
  end

  defp ensure_open(%{log: nil} = state) do
    case RegionLog.open(dir(state.base, state.n)) do
      {:ok, log, _} -> {:ok, %{state | log: log}}
      {:error, _} = error -> error
    end
  end

  defp ensure_open(state) do
    with :ok <- ensure_dir(state), do: {:ok, state}
  end

  # A world folder removed under a running stripe (tests) starts a new log.
  defp ensure_dir(state) do
    if File.dir?(state.log.dir, [:raw]), do: :ok, else: File.mkdir_p(state.log.dir)
  end

  # Owner frames are at most `RegionLog.max_frame/0` each (owners split them);
  # several commits share a RegionLog frame up to `@frame_bytes`, and a
  # commit's frames are never split (a group's commit may exceed it alone).
  defp batches(units) do
    units
    |> Enum.chunk_while(
      {[], 0},
      fn unit, {acc, size} ->
        bytes = unit |> Enum.map(&op_bytes/1) |> Enum.sum()

        # `acc` holds the ops newest first.
        if acc != [] and size + bytes > @frame_bytes,
          do: {:cont, Enum.reverse(acc), {Enum.reverse(unit), bytes}},
          else: {:cont, {Enum.reverse(unit) ++ acc, size + bytes}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
  end

  defp op_bytes({:frame, _, _, frame}), do: byte_size(frame) + 64

  # Everything at or below the first uncovered frame of any owner is covered;
  # segments wholly below it go. The directory is listed only when that
  # floor moved.
  defp prune(%{log: nil} = state), do: state

  defp prune(state) do
    floors = Enum.map(Map.values(state.pending), fn entries -> elem(:queue.get(entries), 1) end)
    floor = if floors == [], do: state.log.next_lsn, else: Enum.min(floors)

    if floor == state.pruned do
      state
    else
      RegionLog.prune(state.log, floor - 1)
      %{state | pruned: floor}
    end
  end
end
