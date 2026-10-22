defmodule Valimc.Player.DropThrottle do
  @moduledoc """
  Vanilla's creative drop admission (`dropSpamThrottler`): each drop costs 20
  of a level that drains by one per tick; at 1480 drops are refused.
  """
  defstruct level: 0, tick: 0

  def new(tick), do: %__MODULE__{tick: tick}

  def charge(input, tick) when is_integer(tick) do
    tick = max(tick, input.tick)
    level = max(input.level - (tick - input.tick), 0)
    input = %{input | tick: tick, level: level}

    if level < 1480,
      do: {:ok, %{input | level: level + 20}},
      else: {:throttled, input}
  end
end
