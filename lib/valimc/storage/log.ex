defmodule Valimc.Storage.Log do
  @moduledoc """
  The world's write-ahead log (VMC-077f): #{8} stripes shared by every owner,
  each a `Valimc.World.RegionLog` segment directory `log/wal.<n>/` under the
  world folder, written by one process. An owner always commits to the stripe
  its key hashes to, so its frames stay in order and a crash loses only a
  suffix of them.

  A stripe drains every queued commit into one append with one `datasync`
  (group commit). An append whose segment does not open (out of descriptors)
  wrote nothing; the stripe holds it and everything after it and tries again
  for up to #{30} seconds before failing them. Two kinds of record go in:

  - **Owner frames** (`commit/5`): one owner's changes of a tick (a region
    section, `Valimc.World.RegionStorage`, or a player,
    `Valimc.Player.Storage`), an opaque binary of keyed records the owner
    encodes, numbered per owner (`seq`). The stripe acknowledges `{:storage_durable,
    owner, seq}` once it is durable; the section folds its frames into its own
    checkpoint file and reports `covered/3` with the last `seq` it holds. A
    loading section reads its frames after its checkpoint with `frames/3`.
  - **Group frames** (`commit_group/4`, VMC-077j): the frames of every section
    and hosted player of a group process from one commit, in one record, so a
    crash keeps all of them or none. A section's frames go to the stripe of the group it is in, so
    they may sit on several stripes over time: its group sends a frame to a new
    stripe only once those before are durable. An index records the stripes a
    section has sent frames to (the sender writes it before the frame, so a
    load after a crash sees frames still in flight; a recovering stripe
    writes what it finds), and `frames/3` reads only those, so one stalled
    stripe holds only the sections it holds frames of.

  A segment is deleted once every frame in it is covered. On start a stripe
  reads its segments: owners with frames newer than their checkpoint files
  are admitted (a section) or folded (a player), so they replay and
  checkpoint them. A stripe stops only once its world folder is
  gone (a removed test world): stopping a live one could lose a commit cast to
  it on the way. Worlds written before this log (per-region `r.X.Z/` logs,
  `players/wal.<n>/`) are refused (D4).
  """
  use GenServer, restart: :temporary
  require Logger
  alias Valimc.Storage.Checkpoint
  alias Valimc.World.RegionLog

  @stripes 8
  @index Valimc.Storage.LogIndex
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

  @doc "Create the index of the stripes owners' frames are on; the application owns it."
  def init! do
    :ets.new(@index, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  defp index(base, owner, n) do
    if :ets.whereis(@index) != :undefined, do: :ets.insert(@index, {{base, owner, n}})
    :ok
  end

  defp indexed(base, owner) do
    if :ets.whereis(@index) != :undefined,
      do: :ets.match(@index, {{base, owner, :"$1"}}) |> List.flatten(),
      else: Enum.to_list(region_stripes())
  end

  @doc """
  Append `frame` (an owner's encoded records, its `seq`-th) for `owner` to its
  stripe of the log under `base`; `notify` receives `{:storage_durable, seq}`
  once it is durable or `{:storage_failed, seq, reason}`. Returns the stripe,
  which the owner monitors: frames in flight on a stripe that went down may
  or may not be durable.
  """
  def commit(base, owner, seq, frame, notify) when is_binary(frame) and is_pid(notify),
    do: commit_group(base, owner, [{owner, seq, frame}], notify)

  @doc """
  Append `frames` (`[{owner, seq, frame}]`, several sections' frames of one
  commit) as one record on the stripe of `route` (a group's key), so they are
  durable together or not at all; `notify` receives `{:storage_durable, owner,
  seq}` for each, or `{:storage_failed, owner, seq, reason}`. Returns the
  stripe for the caller to monitor.
  """
  def commit_group(base, route, frames, notify) when is_list(frames) and is_pid(notify) do
    n = stripe(route)
    for {owner, _, _} <- frames, do: index(base, owner, n)
    stripe = ensure_stripe(base, n)
    GenServer.cast(stripe, {:commit, frames, notify})
    stripe
  end

  @doc """
  The frames of `owner` numbered after `seq` that no checkpoint covers, in
  order, as `[{seq, frame}]`, from every region stripe (a section's group
  decides its stripe).
  """
  def frames(base, owner, seq) do
    # Every stripe recovers (and indexes) its segments when it starts.
    for n <- region_stripes(), do: ensure_stripe(base, n)

    Enum.reduce_while(indexed(base, owner), [], fn n, acc ->
      case GenServer.call(ensure_stripe(base, n), {:frames, owner, seq}, 60_000) do
        frames when is_list(frames) -> {:cont, frames ++ acc}
        error -> {:halt, error}
      end
    end)
    |> case do
      frames when is_list(frames) ->
        frames |> Enum.sort_by(&elem(&1, 0)) |> Enum.dedup_by(&elem(&1, 0))

      error ->
        error
    end
  end

  @doc "`owner`'s checkpoint holds its frames up to `seq` (on every region stripe)."
  def covered(base, owner, seq) do
    for n <- region_stripes(), do: GenServer.cast(ensure_stripe(base, n), {:covered, owner, seq})
    :ok
  end

  @doc "Wait until every commit sent before to `route`'s stripe is appended (durable or failed)."
  def sync(base, route), do: GenServer.call(ensure(base, route), :sync, 60_000)

  @doc "The stripe directory `n` of the world at `base`."
  def dir(base, n), do: Path.join([base, "log", "wal.#{n}"])

  defp ensure(base, owner), do: ensure_stripe(base, stripe(owner))

  defp ensure_stripe(base, n) do
    case Valimc.Owners.ensure(
           Valimc.Owners.registered(Valimc.StorageRegistry, {base, n}),
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
      # owner => queue of {seq, lsn} of its frames no checkpoint covers yet
      pending: %{},
      # {commits, syncs, attempts} held after an unwritten append
      held: nil
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
         {:ok, log, %{frames: frames}} <- RegionLog.open(dir) do
      owners =
        for %{lsn: lsn, ops: ops} <- frames, {:frame, owner, seq, _} <- ops, reduce: %{} do
          acc -> Map.update(acc, owner, [{seq, lsn}], &[{seq, lsn} | &1])
        end

      pending =
        for {owner, entries} <- owners,
            covered = checkpoint_seq(state.base, owner),
            entries = Enum.filter(Enum.reverse(entries), fn {seq, _} -> seq > covered end),
            entries != [],
            into: %{},
            do: {owner, :queue.from_list(entries)}

      # Owners with frames their checkpoint does not cover load, replay and
      # checkpoint them, so the log can be pruned.
      for {owner, _} <- pending, do: index(state.base, owner, state.n)
      for {owner, _} <- pending, do: recover(state.base, owner)
      state = %{state | log: log, pending: pending}
      prune(state)
      {:ok, state}
    end
  rescue
    error in [File.Error, ArgumentError] -> {:error, {:storage_log, Exception.message(error)}}
  end

  defp checkpoint_seq(base, owner) do
    case Checkpoint.seq(Checkpoint.path(base, owner)) do
      {:ok, seq} -> seq
      _ -> -1
    end
  end

  defp recover(_base, {:region, dimension, key}) do
    Task.start(fn ->
      Valimc.World.Directory.admit(Valimc.World.section(dimension, key, :section))
    end)
  end

  defp recover(base, {:player, uuid}), do: Valimc.Player.Storage.recover(base, uuid)
  defp recover(_base, _owner), do: :ok

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

    state = %{state | pending: pending}
    prune(state)
    {:noreply, state, @idle_ms}
  end

  defp drop_covered(entries, seq) do
    case :queue.peek(entries) do
      {:value, {s, _}} when s <= seq -> drop_covered(:queue.drop(entries), seq)
      _ -> entries
    end
  end

  @impl true
  # Only frames no checkpoint covers: a file written anew (a seeded or edited
  # player) does not replay the frames an earlier checkpoint holds.
  def handle_call({:frames, owner, after_seq}, _from, state) do
    uncovered =
      MapSet.new(:queue.to_list(Map.get(state.pending, owner, :queue.new())), &elem(&1, 0))

    case RegionLog.read(dir(state.base, state.n)) do
      {:ok, %{frames: frames}} ->
        {:reply,
         for(
           %{ops: ops} <- frames,
           {:frame, ^owner, seq, frame} <- ops,
           seq > after_seq and MapSet.member?(uncovered, seq),
           do: {seq, frame}
         ), state, @idle_ms}

      error ->
        {:reply, error, state, @idle_ms}
    end
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
        do: :ets.match_delete(@index, {{state.base, :_, state.n}})

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
    Valimc.Metrics.add(:storage_batches)
    Valimc.Metrics.add(:storage_records, length(ops))
    frames = batches(units)

    with {:ok, state} <- ensure_open(state),
         first = state.log.next_lsn,
         {:ok, log, last} <- RegionLog.append(state.log, frames) do
      Valimc.Metrics.add(:storage_bytes, Enum.sum(Enum.map(ops, &op_bytes/1)))

      # Each record's lsn is its RegionLog frame's; owner frames come first.
      lsns = for {frame, lsn} <- Enum.zip(frames, first..last//1), _ <- frame, do: lsn

      for {:commit, frames, notify} <- commits,
          {owner, seq, _} <- frames,
          do: send(notify, {:storage_durable, owner, seq})

      for from <- syncs, do: GenServer.reply(from, :ok)

      pending =
        commits
        |> Enum.flat_map(fn {:commit, frames, _} ->
          for {owner, seq, _} <- frames, do: {owner, seq}
        end)
        |> Enum.zip(lsns)
        |> Enum.reduce(state.pending, fn {{owner, seq}, lsn}, acc ->
          Map.update(acc, owner, :queue.from_list([{seq, lsn}]), &:queue.in({seq, lsn}, &1))
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
  # segments wholly below it go.
  defp prune(%{log: nil}), do: :ok

  defp prune(state) do
    floors = Enum.map(Map.values(state.pending), fn entries -> elem(:queue.get(entries), 1) end)

    floor = if floors == [], do: state.log.next_lsn, else: Enum.min(floors)
    RegionLog.prune(state.log, floor - 1)
  end
end
