defmodule Valimc.Player.MiningAttempt do
  @moduledoc "One player-owned mining attempt; elapsed owner ticks never grant world mutation authority."
  alias Valimc.Blocks.Mining
  @enforce_keys [:token, :position, :state, :started, :observed, :phase, :crack]
  defstruct [:token, :position, :state, :started, :observed, :phase, :crack]

  def start(position, state, rate, tick) when is_integer(tick) and tick >= 0 do
    with {:ok, progress} <- Mining.advance(rate, 0) do
      attempt = %__MODULE__{
        token: make_ref(),
        position: position,
        state: state,
        started: tick,
        observed: tick,
        phase: if(progress.complete, do: :ready, else: :active),
        crack: if(progress.complete, do: -1, else: stage(progress.crack))
      }

      {:ok, attempt, if(progress.complete, do: [:ready], else: [{:crack, attempt.crack}])}
    end
  end

  @doc "Active ticks update cracks; only a stopped, finishing attempt completes automatically."
  def tick(%__MODULE__{phase: phase} = attempt, state, rate, tick)
      when phase in [:active, :finishing] and is_integer(tick) do
    cond do
      tick <= attempt.observed ->
        {:ok, attempt, []}

      state != attempt.state ->
        cancel(attempt)

      true ->
        with {:ok, progress} <- Mining.advance(rate, tick - attempt.started) do
          attempt = %{attempt | observed: tick}

          if phase == :finishing and progress.complete,
            do: ready(attempt),
            else: cracks(attempt, progress.crack)
        end
    end
  end

  def tick(%__MODULE__{} = attempt, _, _, _), do: {:ok, attempt, []}

  @doc "Native stop uses current rate times elapsed+1, with its distinct 0.7 threshold."
  def stop(%__MODULE__{phase: :active} = attempt, state, rate, tick)
      when is_integer(tick) and tick >= attempt.observed do
    if state == attempt.state do
      with {:ok, progress} <- Mining.advance(rate, tick - attempt.started) do
        attempt = %{attempt | observed: tick}

        if progress.stoppable,
          do: ready(attempt),
          else: {:ok, %{attempt | phase: :finishing}, []}
      end
    else
      cancel(attempt)
    end
  end

  def stop(%__MODULE__{} = attempt, _, _, _), do: {:ok, attempt, []}

  @doc "Retirement consumes this identity, including delayed completion and in-flight callbacks."
  def cancel(%__MODULE__{phase: :cancelled} = attempt), do: {:ok, attempt, []}

  def cancel(%__MODULE__{} = attempt),
    do: {:ok, %{attempt | phase: :cancelled, crack: -1}, [{:crack, -1}]}

  defp ready(attempt),
    do: {:ok, %{attempt | phase: :ready, crack: -1}, [{:crack, -1}, :ready]}

  defp cracks(attempt, raw) do
    stage = stage(raw)
    events = if stage == attempt.crack, do: [], else: [{:crack, stage}]
    {:ok, %{attempt | crack: stage}, events}
  end

  defp stage(raw) when raw in 0..9, do: raw
  defp stage(_), do: -1
end
