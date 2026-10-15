defmodule Valimc.World.TickClock do
  @moduledoc "Owner-local logical ticks and single-use timer identities; no simulation order is implied."
  defstruct [:epoch, :token, :deadline, tick: 0]
  @interval 50

  def new(epoch, now) when is_reference(epoch) and is_integer(now),
    do: %__MODULE__{epoch: epoch, token: {epoch, make_ref()}, deadline: now + @interval}

  def advance(%__MODULE__{token: token} = clock, token, now) when is_integer(now) do
    next = %{clock | token: {clock.epoch, make_ref()}}

    if now < clock.deadline do
      {:early, next, clock.deadline - now}
    else
      deadline = max(clock.deadline + @interval, now + 1)
      next = %{next | deadline: deadline, tick: clock.tick + 1}
      {:ok, next, now - clock.deadline, deadline - now}
    end
  end

  def advance(%__MODULE__{}, _, _), do: :stale
end
