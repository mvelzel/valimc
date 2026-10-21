defmodule Valimc.World.TickClock do
  @moduledoc """
  Owner-local logical ticks and single-use timer identities; no simulation order
  is implied. Ticks are `Valimc.World.TickRate.interval/0` apart (50 ms at the
  default 20 per second, as fast as possible while sprinting).
  """
  defstruct [:epoch, :token, :deadline, tick: 0]

  def new(epoch, now) when is_reference(epoch) and is_integer(now),
    do: %__MODULE__{
      epoch: epoch,
      token: {epoch, make_ref()},
      deadline: now + Valimc.World.TickRate.interval()
    }

  def advance(%__MODULE__{token: token} = clock, token, now) when is_integer(now) do
    next = %{clock | token: {clock.epoch, make_ref()}}

    if now < clock.deadline do
      {:early, next, ceil(clock.deadline - now)}
    else
      deadline = max(clock.deadline + Valimc.World.TickRate.interval(), now + 1)
      next = %{next | deadline: deadline, tick: clock.tick + 1}
      {:ok, next, trunc(now - clock.deadline), ceil(deadline - now)}
    end
  end

  def advance(%__MODULE__{}, _, _), do: :stale
end
