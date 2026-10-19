defmodule Valimc.ChatThrottle do
  @moduledoc """
  Vanilla chat spam throttle: every chat message or command adds 20 and one is
  forgiven per elapsed game tick; reaching 200 disconnects with `disconnect.spam`.
  """
  @increment 20
  @threshold 200
  @tick_ms 50

  defstruct count: 0, at_tick: 0

  def new(now_ms \\ System.monotonic_time(:millisecond)),
    do: %__MODULE__{at_tick: div(now_ms, @tick_ms)}

  @doc "Record one message; `:spam` means the sender exceeded the vanilla threshold."
  def record(%__MODULE__{} = throttle, now_ms \\ System.monotonic_time(:millisecond)) do
    tick = div(now_ms, @tick_ms)
    count = max(throttle.count - (tick - throttle.at_tick), 0) + @increment
    throttle = %__MODULE__{count: count, at_tick: tick}
    if count < @threshold, do: {:ok, throttle}, else: {:spam, throttle}
  end
end
