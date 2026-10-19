defmodule Valimc.PlayerLog do
  @moduledoc """
  Group commit for player snapshots (VMC-063 step 9).

  A few partitioned writers (chosen by file path) each keep a `RegionLog` in
  `players/wal.<n>/`. A writer drains every save queued by any player into one
  frame with one `datasync`, then writes the player files themselves (page cache,
  no fsync) and replies, so files are always current for readers while the log
  carries durability. A checkpoint task fsyncs the files written since the last
  checkpoint and the directory, then prunes the covered log. Opening a log replays
  its frames into the files before any player of that directory is served.
  """
  use GenServer
  require Logger
  alias Valimc.World.RegionLog

  @max_batch 512
  @checkpoint_bytes 4 * 1024 * 1024

  def child_spec(_),
    do: %{
      id: __MODULE__,
      start:
        {PartitionSupervisor, :start_link,
         [
           [
             child_spec: %{id: __MODULE__, start: {__MODULE__, :start_link, []}},
             name: Valimc.PlayerLogs,
             partitions: min(System.schedulers_online(), 8),
             with_arguments: fn [], partition -> [partition] end
           ]
         ]},
      type: :supervisor
    }

  def start_link(partition), do: GenServer.start_link(__MODULE__, partition)

  @doc "Durably store `bytes` as the player file `path`; returns once the frame is durable."
  def commit(path, bytes) when is_binary(path) and is_binary(bytes),
    do:
      GenServer.call(
        {:via, PartitionSupervisor, {Valimc.PlayerLogs, path}},
        {:commit, Path.dirname(path), path, bytes},
        10_000
      )

  @impl true
  def init(partition) do
    state = %{
      partition: partition,
      dir: nil,
      log: nil,
      dirty: %{},
      appended: 0,
      checkpointing: nil
    }

    # Replay a crashed run's frames before any player of the configured world loads.
    case Valimc.config(:world_path) do
      nil ->
        {:ok, state}

      base ->
        case ensure_log(state, Path.join(base, "players")) do
          {:ok, state} -> {:ok, state}
          {:error, reason, _} -> {:stop, {:player_log_recovery_failed, reason}}
        end
    end
  end

  @impl true
  def handle_call({:commit, dir, _path, _bytes} = first, from, state) do
    batch = [{from, first} | drain(dir, @max_batch - 1, [])]

    case ensure_log(state, dir) do
      {:ok, state} ->
        commit_batch(state, batch)

      {:error, reason, state} ->
        Logger.error("Player log unavailable: #{inspect(reason)}")
        for {from, _} <- batch, do: GenServer.reply(from, {:error, reason})
        {:noreply, state}
    end
  end

  defp commit_batch(state, batch) do
    # Absolute values: the last snapshot of each player in the batch wins.
    latest =
      Enum.reduce(batch, %{}, fn {_, {:commit, _, path, bytes}}, acc ->
        Map.put(acc, path, bytes)
      end)

    ops = for {path, bytes} <- latest, do: {:player, Path.basename(path), bytes}
    Valimc.Metrics.add(:player_log_batches)
    Valimc.Metrics.add(:player_log_commits, length(batch))

    case RegionLog.append(state.log, [ops]) do
      {:ok, log, _lsn} ->
        result = write_files(latest)
        for {from, _} <- batch, do: GenServer.reply(from, result)
        generation = make_ref()
        dirty = Enum.reduce(Map.keys(latest), state.dirty, &Map.put(&2, &1, generation))
        appended = state.appended + IO.iodata_length(Enum.map(ops, &elem(&1, 2)))
        {:noreply, maybe_checkpoint(%{state | log: log, dirty: dirty, appended: appended})}

      {:error, reason} ->
        Logger.error("Player log append failed: #{inspect(reason)}")
        for {from, _} <- batch, do: GenServer.reply(from, {:error, reason})
        # A torn frame may only be repaired by recovery: restart and reopen.
        {:stop, {:player_log_failed, reason}, state}
    end
  end

  @impl true
  def handle_info({:checkpointed, ref, written, result}, %{checkpointing: ref} = state) do
    dirty =
      if result == :ok,
        do: Map.reject(state.dirty, fn {path, gen} -> written[path] == gen end),
        else: state.dirty

    {:noreply, %{state | checkpointing: nil, dirty: dirty}}
  end

  def handle_info(_, state), do: {:noreply, state}

  # Saves from many players arrive as concurrent calls; each sender waits for its
  # reply, so taking them ahead of other messages reorders nothing per player.
  defp drain(_dir, 0, acc), do: Enum.reverse(acc)

  defp drain(dir, left, acc) do
    receive do
      {:"$gen_call", from, {:commit, ^dir, _, _} = message} ->
        drain(dir, left - 1, [{from, message} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # The open log serves one players directory; a vanished directory (its log file
  # would be unlinked) or another directory reopens, replaying newer frames first.
  defp ensure_log(%{dir: dir, log: log} = state, dir) when log != nil do
    if File.dir?(log.dir), do: {:ok, state}, else: ensure_log(%{state | dir: nil}, dir)
  end

  defp ensure_log(state, dir) do
    if state.log, do: RegionLog.close(state.log)
    state = %{state | dir: nil, log: nil, dirty: %{}, appended: 0, checkpointing: nil}
    wal = Path.join(dir, "wal.#{state.partition}")

    with :ok <- File.mkdir_p(wal),
         {:ok, log, %{frames: frames}} <- RegionLog.open(wal),
         replay =
           for(
             %{ops: ops} <- frames,
             {:player, name, bytes} <- ops,
             into: %{},
             do: {Path.join(dir, name), bytes}
           ),
         # Frames newer than the files (a crash before their write reached disk).
         :ok <- write_files(replay),
         :ok <- sync_files(Map.keys(replay), dir),
         {:ok, log} <- if(replay == %{}, do: {:ok, log}, else: RegionLog.checkpoint(log, %{})) do
      {:ok, %{state | dir: dir, log: log}}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp write_files(files) when map_size(files) == 0, do: :ok

  defp write_files(files) do
    Enum.reduce_while(files, :ok, fn {path, bytes}, :ok ->
      tmp = path <> ".tmp"

      case with(:ok <- File.write(tmp, bytes, [:binary, :raw]), do: File.rename(tmp, path)) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp sync_files(paths, dir) do
    with :ok <- Enum.reduce_while(paths, :ok, fn path, :ok -> sync_file(path) end),
         {:ok, :ok} <- Valimc.Native.fsync_dir(dir),
         do: :ok
  end

  defp sync_file(path) do
    case Valimc.Native.full_sync(path) do
      {:ok, :ok} -> {:cont, :ok}
      {:error, reason} -> {:halt, {:error, reason}}
    end
  end

  defp maybe_checkpoint(%{appended: appended} = state) when appended < @checkpoint_bytes,
    do: state

  defp maybe_checkpoint(%{checkpointing: ref} = state) when ref != nil, do: state

  defp maybe_checkpoint(state) do
    {:ok, log, job} = RegionLog.begin_checkpoint(state.log)
    writer = self()
    ref = make_ref()
    written = state.dirty
    dir = state.dir

    {:ok, _} =
      Task.start_link(fn ->
        result =
          with :ok <- sync_files(Map.keys(written), dir),
               do: RegionLog.write_checkpoint(job, %{})

        send(writer, {:checkpointed, ref, written, result})
      end)

    %{state | log: log, appended: 0, checkpointing: ref}
  end
end
