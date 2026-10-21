defmodule Valimc.Worldgen.ProtoLog do
  @moduledoc """
  The durable state of one region's proto owner (VMC-025d2), written by this
  process so the owner never waits on a disk. It is a `RegionLog` directory
  (`gen/r.X.Z` under the world) of frames of operations:

  - `{:chunks, %{chunk => {status, image}}}`: proto chunks a decoration
    changed or decorated (`status` `:terrain` or `:decorated`); chunks that
    are pure terrain are not stored, since terrain is a function of seed and
    position;
  - `{:final, chunks}` and `{:dropped, chunks}`: own chunks that became final,
    and final chunks the live region now holds (their images go);
  - `{:lock, txn, grant}` and `{:unlock, txn}`: locks this owner granted a
    foreign finalize transaction (durable prepare);
  - `{:outbox, txn, parts}` and `{:delivered, txn, key}`: a committed
    transaction's parts for its foreign participants, until applied;
  - `{:receipt, source, receipt}`: the last part applied from a coordinator
    (`Txn.Receipts`).

  Appends are casts acknowledged to the owner as `{:proto_saved, token,
  result}` in order; every append already queued joins one frame batch with
  one `datasync` (group commit). The writer folds frames into the same state
  the owner recovers from, and checkpoints it once frames pass
  `:proto_checkpoint_bytes`. Without a world path the state stays in memory.
  """
  use GenServer

  @max_batch 64
  @empty %{
    chunks: %{},
    final: MapSet.new(),
    dropped: MapSet.new(),
    locks: %{},
    outbox: %{},
    receipts: %{}
  }

  def empty, do: @empty

  @doc """
  Start the writer for `dir` (nil: memory only), linked to the caller, and
  recover: `{:ok, pid, state, incarnation}`.
  """
  def open(dir, checkpoint_bytes \\ 8 * 1024 * 1024) do
    with {:ok, pid} <- GenServer.start_link(__MODULE__, {dir, checkpoint_bytes}),
         {:ok, state, incarnation} <- GenServer.call(pid, :recovered, 60_000),
         do: {:ok, pid, state, incarnation}
  end

  @doc "Append `ops` as one frame; the owner receives `{:proto_saved, token, result}`."
  def append(pid, ops, token) when is_list(ops),
    do: GenServer.cast(pid, {:append, self(), ops, token})

  @doc "The folded state of `ops` over `state` (recovery and the writer's copy)."
  def fold(state, ops) do
    Enum.reduce(ops, state, fn
      {:chunks, chunks}, acc ->
        %{acc | chunks: Map.merge(acc.chunks, chunks)}

      {:final, chunks}, acc ->
        %{acc | final: MapSet.union(acc.final, MapSet.new(chunks))}

      {:dropped, chunks}, acc ->
        %{
          acc
          | dropped: MapSet.union(acc.dropped, MapSet.new(chunks)),
            chunks: Map.drop(acc.chunks, chunks)
        }

      {:lock, txn, grant}, acc ->
        %{acc | locks: Map.put(acc.locks, txn, grant)}

      {:unlock, txn}, acc ->
        %{acc | locks: Map.delete(acc.locks, txn)}

      {:outbox, txn, parts}, acc ->
        %{acc | outbox: Map.put(acc.outbox, txn, parts)}

      {:delivered, txn, key}, acc ->
        case acc.outbox do
          %{^txn => parts} ->
            parts = Map.delete(parts, key)

            outbox =
              if map_size(parts) == 0,
                do: Map.delete(acc.outbox, txn),
                else: Map.put(acc.outbox, txn, parts)

            %{acc | outbox: outbox}

          _ ->
            acc
        end

      {:receipt, source, receipt}, acc ->
        %{acc | receipts: Map.put(acc.receipts, source, receipt)}

      _, acc ->
        acc
    end)
  end

  @impl true
  def init({dir, checkpoint_bytes}) do
    case recover(dir) do
      {:ok, log, state, incarnation} ->
        {:ok,
         %{
           log: log,
           state: state,
           incarnation: incarnation,
           appended: 0,
           checkpoint_bytes: checkpoint_bytes
         }}

      {:error, reason} ->
        {:stop, {:proto_log_recovery_failed, reason}}
    end
  end

  defp recover(nil), do: {:ok, nil, @empty, 1}

  defp recover(dir) do
    with {:ok, log, %{checkpoint: checkpoint, frames: frames}} <-
           Valimc.World.RegionLog.open(dir) do
      state =
        Enum.reduce(frames, Map.merge(@empty, checkpoint || %{}), fn %{ops: ops}, acc ->
          fold(acc, ops)
        end)

      {:ok, log, state, log.incarnation}
    end
  rescue
    error in [File.Error, MatchError, ArgumentError] -> {:error, Exception.message(error)}
  end

  @impl true
  def handle_call(:recovered, _from, s), do: {:reply, {:ok, s.state, s.incarnation}, s}

  @impl true
  def handle_cast({:append, owner, ops, token}, s) do
    batch = [{owner, ops, token} | drain(@max_batch - 1, [])]
    Valimc.Metrics.add(:proto_log_batches)

    {result, s} =
      case s.log do
        nil ->
          {:ok, s}

        log ->
          case Valimc.World.RegionLog.append(log, Enum.map(batch, &elem(&1, 1))) do
            {:ok, log, _lsn} ->
              bytes = Enum.sum(Enum.map(batch, &:erlang.external_size(elem(&1, 1))))
              {:ok, %{s | log: log, appended: s.appended + bytes}}

            {:error, reason} ->
              {{:error, reason}, s}
          end
      end

    s =
      if result == :ok,
        do: %{s | state: Enum.reduce(batch, s.state, fn {_, ops, _}, acc -> fold(acc, ops) end)},
        else: s

    for {owner, _, token} <- batch, do: send(owner, {:proto_saved, token, result})

    case result do
      # An append that failed may have left a torn frame; only recovery may continue.
      {:error, reason} -> {:stop, {:proto_log_failed, reason}, s}
      :ok -> {:noreply, maybe_checkpoint(s)}
    end
  end

  defp drain(0, acc), do: Enum.reverse(acc)

  defp drain(left, acc) do
    receive do
      {:"$gen_cast", {:append, owner, ops, token}} -> drain(left - 1, [{owner, ops, token} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  # Checkpoints are small (a region's non-final chunks at most), so the writer
  # writes them itself after an append.
  defp maybe_checkpoint(%{log: nil} = s), do: s
  defp maybe_checkpoint(%{appended: a, checkpoint_bytes: limit} = s) when a < limit, do: s

  defp maybe_checkpoint(s) do
    case Valimc.World.RegionLog.checkpoint(s.log, s.state) do
      {:ok, log} -> %{s | log: log, appended: 0}
      {:error, _} -> %{s | appended: div(s.checkpoint_bytes, 2)}
    end
  end

  @impl true
  def terminate(_reason, %{log: log}) when log != nil, do: Valimc.World.RegionLog.close(log)
  def terminate(_, _), do: :ok
end
