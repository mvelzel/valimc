defmodule Valimc.World.ClockState do
  @moduledoc "Pure core-pack clock arithmetic, rounded at Mojang's float32 operation boundaries."
  alias Valimc.Data.Float32
  import Bitwise
  alias Valimc.Protocol.Wire
  defstruct total_ticks: 0, partial_tick: 0.0, rate: 1.0, paused: false

  def valid?(%__MODULE__{total_ticks: total, partial_tick: partial, rate: rate, paused: paused}),
    do:
      is_integer(total) and total in -9_223_372_036_854_775_808..9_223_372_036_854_775_807 and
        is_float(partial) and partial >= 0.0 and partial < 1.0 and
        is_float(rate) and rate >= 0.0 and rate <= 1024.0 and is_boolean(paused)

  def valid?(_), do: false

  def long(value) do
    unsigned = value &&& 0xFFFFFFFFFFFFFFFF
    if unsigned >= 0x8000000000000000, do: unsigned - 0x10000000000000000, else: unsigned
  end

  def tick(%__MODULE__{paused: true} = clock), do: clock

  def tick(%__MODULE__{} = clock) do
    partial = Float32.round(clock.partial_tick + clock.rate)
    whole = floor(partial)

    %{
      clock
      | total_ticks: long(clock.total_ticks + whole),
        partial_tick: Float32.round(partial - Float32.round(whole))
    }
  end

  def set_ticks(clock, total) when is_integer(total),
    do: %{clock | total_ticks: total, partial_tick: 0.0}

  def network(clock, advance_time) do
    rate = if clock.paused or not advance_time, do: 0.0, else: clock.rate
    [Wire.varlong(clock.total_ticks), <<clock.partial_tick::float-32, rate::float-32>>]
  end
end
