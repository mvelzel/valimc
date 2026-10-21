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

  - **Owner frames** (`commit/5`): one region owner's changes of a tick, an
    opaque binary of keyed records the owner encodes (`Valimc.World.RegionStorage`),
    numbered by the owner (`seq`). The stripe acknowledges `{:storage_durable,
    seq}` to the owner once it is durable; the owner folds its frames into its
    own checkpoint file and reports `covered/3` with the last `seq` it holds. A
    loading owner reads its frames after its checkpoint with `frames/3`.
  - **File records** (`commit_file/3`): a player file's whole bytes. The call
    returns once durable; the stripe then writes the file (page cache) and
    covers the record itself once a checkpoint has fsynced the file.

  A segment is deleted once every frame in it is covered. On start a stripe
  reads its segments: file records are written to their files again and
  synced; owners with frames newer than their checkpoint files are admitted, so
  they replay and checkpoint them. A stripe stops only once its world folder is
  gone (a removed test world): stopping a live one could lose a commit cast to
  it on the way. Worlds written before this log (per-region `r.X.Z/` logs,
  `players/wal.<n>/`) are refused (D4).
  """
  use GenServer, restart: :temporary
  require Logger
  alias Valimc.Storage.Checkpoint
  alias Valimc.World.RegionLog

  @stripes 8
  @file_stripes 2
  @idle_ms 15_000
  @retry_ms 100
  @retries 300
  @max_batch 512
  # Several owner frames share a RegionLog frame up to this many bytes.
  @frame_bytes 16 * 1024 * 1024
  @file_checkpoint_bytes 4 * 1024 * 1024

  @doc "How many stripes a world's log has."
  def stripes, do: @stripes

  @doc """
  The stripe of an owner key. Player files take the last #{2} stripes, so a
  player's save never queues behind a region's large frame.
  """
  def stripe({:file, _} = owner),
    do: @stripes - @file_stripes + :erlang.phash2(owner, @file_stripes)

  def stripe(owner), do: :erlang.phash2(owner, @stripes - @file_stripes)

  @doc """
  Append `frame` (an owner's encoded records, its `seq`-th) for `owner` to its
  stripe of the log under `base`; `notify` receives `{:storage_durable, seq}`
  once it is durable or `{:storage_failed, seq, reason}`. Returns the stripe,
  which the owner monitors: frames in flight on a stripe that went down may
  or may not be durable.
  """
  def commit(base, owner, seq, frame, notify) when is_binary(frame) and is_pid(notify) do
    stripe = ensure(base, owner)
    GenServer.cast(stripe, {:commit, owner, seq, frame, notify})
    stripe
  end

  @doc "Durably store `bytes` as the file `path` under `base`; returns once durable."
  def commit_file(base, path, bytes) when is_binary(path) and is_binary(bytes) do
    relative = Path.relative_to(path, base)
    GenServer.call(ensure(base, {:file, relative}), {:file, relative, bytes}, 10_000)
  catch
    :exit, reason -> {:error, {:storage_log, reason}}
  end

  @doc "The frames of `owner` numbered after `seq`, in order, as `[{seq, frame}]`."
  def frames(base, owner, seq),
    do: GenServer.call(ensure(base, owner), {:frames, owner, seq}, 60_000)

  @doc "`owner`'s checkpoint holds its frames up to `seq`."
  def covered(base, owner, seq), do: GenServer.cast(ensure(base, owner), {:covered, owner, seq})

  @doc "Wait until every commit `owner` sent before is appended (durable or failed)."
  def sync(base, owner), do: GenServer.call(ensure(base, owner), :sync, 60_000)

  @doc "The stripe directory `n` of the world at `base`."
  def dir(base, n), do: Path.join([base, "log", "wal.#{n}"])

  defp ensure(base, owner) do
    n = stripe(owner)

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
      # file path => lsn of its newest record, written but not yet fsynced
      files: %{},
      file_bytes: 0,
      checkpointing: nil,
      # {commits, files, attempts} held after an unwritten append
      held: nil
    }

    case open(state) do
      {:ok, state} -> {:ok, state, @idle_ms}
      {:error, reason} -> {:stop, reason}
    end
  end

  # Open the stripe and recover it: files replayed and synced, owners' covered
  # frames found from their checkpoint files.
  defp open(state) do
    dir = dir(state.base, state.n)
    old = Path.wildcard(Path.join([state.base, "players", "wal.*"]))

    with :ok <- if(old == [], do: :ok, else: {:error, {:old_player_log, old}}),
         {:ok, log, %{frames: frames}} <- RegionLog.open(dir) do
      files = for %{ops: ops} <- frames, {:file, path, bytes} <- ops, into: %{}, do: {path, bytes}

      owners =
        for %{lsn: lsn, ops: ops} <- frames, {:frame, owner, seq, _} <- ops, reduce: %{} do
          acc -> Map.update(acc, owner, [{seq, lsn}], &[{seq, lsn} | &1])
        end

      with :ok <- write_files(state.base, files),
           :ok <- sync_files(state.base, Map.keys(files)) do
        pending =
          for {owner, entries} <- owners,
              covered = checkpoint_seq(state.base, owner),
              entries = Enum.filter(Enum.reverse(entries), fn {seq, _} -> seq > covered end),
              entries != [],
              into: %{},
              do: {owner, :queue.from_list(entries)}

        # Owners with frames their checkpoint does not cover load, replay and
        # checkpoint them, so the log can be pruned.
        for {owner, _} <- pending, do: recover(owner)
        state = %{state | log: log, pending: pending}
        prune(state)
        {:ok, state}
      end
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

  defp recover({:region, dimension, key}) do
    Task.start(fn ->
      Valimc.Dimension.within(dimension, fn -> Valimc.World.Directory.admit(key) end)
    end)
  end

  defp recover(_), do: :ok

  @impl true
  def handle_cast({:commit, _, _, _, _} = first, %{held: nil} = state) do
    {commits, files} = drain([first], [], @max_batch - 1)
    append(state, commits, files)
  end

  def handle_cast({:commit, _, _, _, _} = commit, %{held: {commits, files, n}} = state),
    do: {:noreply, %{state | held: {commits ++ [commit], files, n}}, @idle_ms}

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
  def handle_call({:file, _, _} = first, from, %{held: nil} = state) do
    {commits, files} = drain([], [{from, first}], @max_batch - 1)
    append(state, commits, files)
  end

  def handle_call({:file, _, _} = file, from, %{held: {commits, files, n}} = state),
    do: {:noreply, %{state | held: {commits, files ++ [{from, file}], n}}, @idle_ms}

  def handle_call({:frames, owner, after_seq}, _from, state) do
    case RegionLog.read(state.log.dir) do
      {:ok, %{frames: frames}} ->
        {:reply,
         for(
           %{ops: ops} <- frames,
           {:frame, ^owner, seq, frame} <- ops,
           seq > after_seq,
           do: {seq, frame}
         ), state, @idle_ms}

      error ->
        {:reply, error, state, @idle_ms}
    end
  end

  # Held appends answer once they land or fail.
  def handle_call(:sync, from, %{held: {commits, files, n}} = state),
    do: {:noreply, %{state | held: {commits, files ++ [{from, :sync}], n}}, @idle_ms}

  def handle_call(:sync, _from, state), do: {:reply, :ok, state, @idle_ms}

  @impl true
  def handle_info({:checkpointed, ref, written, result}, %{checkpointing: ref} = state) do
    files =
      if result == :ok,
        do: Map.reject(state.files, fn {path, lsn} -> written[path] == lsn end),
        else: state.files

    state = %{state | checkpointing: nil, files: files}
    prune(state)
    {:noreply, state, @idle_ms}
  end

  def handle_info(:retry, %{held: {commits, files, n}} = state),
    do: append(%{state | held: nil}, commits, files, n + 1)

  def handle_info(:timeout, %{checkpointing: nil, held: nil} = state) do
    if File.dir?(state.base, [:raw]),
      do: {:noreply, state, @idle_ms},
      else: {:stop, :normal, state}
  end

  def handle_info(_, state), do: {:noreply, state, @idle_ms}

  # Commits from many owners arrive as casts and calls; each owner's stay in
  # order, so taking them ahead of other messages reorders nothing per owner.
  defp drain(commits, files, 0), do: {Enum.reverse(commits), Enum.reverse(files)}

  defp drain(commits, files, left) do
    receive do
      {:"$gen_cast", {:commit, _, _, _, _} = commit} ->
        drain([commit | commits], files, left - 1)

      {:"$gen_call", from, {:file, _, _} = file} ->
        drain(commits, [{from, file} | files], left - 1)
    after
      0 -> {Enum.reverse(commits), Enum.reverse(files)}
    end
  end

  defp append(state, commits, entries, attempts \\ 0) do
    {syncs, files} = Enum.split_with(entries, &match?({_, :sync}, &1))

    ops =
      Enum.map(commits, fn {:commit, owner, seq, frame, _} -> {:frame, owner, seq, frame} end) ++
        Enum.map(files, fn {_, {:file, path, bytes}} -> {:file, path, bytes} end)

    Valimc.Metrics.add(:storage_batches)
    Valimc.Metrics.add(:storage_records, length(ops))
    frames = batches(ops)

    with :ok <- ensure_dir(state),
         first = state.log.next_lsn,
         {:ok, log, last} <- RegionLog.append(state.log, frames) do
      Valimc.Metrics.add(:storage_bytes, Enum.sum(Enum.map(ops, &op_bytes/1)))

      # Each record's lsn is its RegionLog frame's; owner frames come first.
      lsns = for {frame, lsn} <- Enum.zip(frames, first..last//1), _ <- frame, do: lsn

      for {:commit, _, seq, _, notify} <- commits, do: send(notify, {:storage_durable, seq})

      latest = Map.new(files, fn {_, {:file, path, bytes}} -> {path, bytes} end)
      result = write_files(state.base, latest)
      for {from, _} <- files, do: GenServer.reply(from, result)
      for {from, _} <- syncs, do: GenServer.reply(from, :ok)

      pending =
        commits
        |> Enum.zip(lsns)
        |> Enum.reduce(state.pending, fn {{:commit, owner, seq, _, _}, lsn}, acc ->
          Map.update(acc, owner, :queue.from_list([{seq, lsn}]), &:queue.in({seq, lsn}, &1))
        end)

      state = %{
        state
        | log: log,
          pending: pending,
          files: Enum.reduce(Map.keys(latest), state.files, &Map.put(&2, &1, last)),
          file_bytes: state.file_bytes + Enum.sum(Enum.map(Map.values(latest), &byte_size/1))
      }

      {:noreply, maybe_checkpoint_files(state), @idle_ms}
    else
      # Nothing was written: hold the batch, and what follows, and try again.
      {:error, {:unwritten, _}} when attempts < @retries ->
        Process.send_after(self(), :retry, @retry_ms)
        {:noreply, %{state | held: {commits, entries, attempts}}, @idle_ms}

      {:error, reason} ->
        Logger.error("Storage log append failed: #{inspect(reason)}")

        for {:commit, _, seq, _, notify} <- commits,
            do: send(notify, {:storage_failed, seq, reason})

        for {from, _} <- files, do: GenServer.reply(from, {:error, reason})
        for {from, _} <- syncs, do: GenServer.reply(from, :ok)

        # A torn frame may only be repaired by recovery: reopen the stripe.
        case reason do
          {:unwritten, _} -> {:noreply, state, @idle_ms}
          _ -> reopen(state)
        end
    end
  end

  defp reopen(state) do
    case RegionLog.open(dir(state.base, state.n)) do
      {:ok, log, _} -> {:noreply, %{state | log: log}, @idle_ms}
      {:error, reason} -> {:stop, {:storage_log_failed, reason}, state}
    end
  end

  # A world folder removed under a running stripe (tests) starts a new log.
  defp ensure_dir(state) do
    if File.dir?(state.log.dir, [:raw]), do: :ok, else: File.mkdir_p(state.log.dir)
  end

  # Owner frames are at most `RegionLog.max_frame/0` each (owners split them);
  # several share a RegionLog frame up to `@frame_bytes`.
  defp batches(ops) do
    ops
    |> Enum.chunk_while(
      {[], 0},
      fn op, {acc, size} ->
        bytes = op_bytes(op)

        if acc != [] and size + bytes > @frame_bytes,
          do: {:cont, Enum.reverse(acc), {[op], bytes}},
          else: {:cont, {[op | acc], size + bytes}}
      end,
      fn
        {[], _} -> {:cont, {[], 0}}
        {acc, _} -> {:cont, Enum.reverse(acc), {[], 0}}
      end
    )
  end

  defp op_bytes({:frame, _, _, frame}), do: byte_size(frame) + 64
  defp op_bytes({:file, path, bytes}), do: byte_size(bytes) + byte_size(path) + 64

  defp write_files(_base, files) when map_size(files) == 0, do: :ok

  defp write_files(base, files) do
    Enum.reduce_while(files, :ok, fn {path, bytes}, :ok ->
      path = Path.join(base, path)
      tmp = path <> ".tmp"

      result =
        with :ok <- File.mkdir_p(Path.dirname(path)),
             :ok <- File.write(tmp, bytes, [:binary, :raw]),
             do: File.rename(tmp, path)

      case result do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp sync_files(_base, []), do: :ok

  defp sync_files(base, paths) do
    with :ok <-
           Enum.reduce_while(paths, :ok, fn path, :ok ->
             case Valimc.Native.full_sync(Path.join(base, path)) do
               :ok -> {:cont, :ok}
               {:error, reason} -> {:halt, {:error, reason}}
             end
           end) do
      paths
      |> Enum.map(&Path.dirname(Path.join(base, &1)))
      |> Enum.uniq()
      |> Enum.reduce_while(:ok, fn dir, :ok ->
        case Valimc.Native.fsync_dir(dir) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
    end
  end

  # Written files are fsynced by a task once their bytes add up; their records
  # are covered then.
  defp maybe_checkpoint_files(%{file_bytes: bytes} = state) when bytes < @file_checkpoint_bytes,
    do: state

  defp maybe_checkpoint_files(%{checkpointing: ref} = state) when ref != nil, do: state

  defp maybe_checkpoint_files(state) do
    stripe = self()
    ref = make_ref()
    written = state.files
    base = state.base

    {:ok, _} =
      Task.start_link(fn ->
        send(stripe, {:checkpointed, ref, written, sync_files(base, Map.keys(written))})
      end)

    %{state | checkpointing: ref, file_bytes: 0}
  end

  # Everything at or below the first uncovered frame of any owner or file is
  # covered; segments wholly below it go.
  defp prune(%{log: nil}), do: :ok

  defp prune(state) do
    floors =
      Enum.map(Map.values(state.pending), fn entries -> elem(:queue.get(entries), 1) end) ++
        Map.values(state.files)

    floor = if floors == [], do: state.log.next_lsn, else: Enum.min(floors)
    RegionLog.prune(state.log, floor - 1)
  end
end
