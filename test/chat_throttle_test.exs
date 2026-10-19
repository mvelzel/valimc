defmodule Valimc.ChatThrottleTest do
  use ExUnit.Case, async: true
  alias Valimc.ChatThrottle

  test "a burst of nine messages passes and the tenth within one tick is spam" do
    throttle = ChatThrottle.new(0)

    throttle =
      Enum.reduce(1..9, throttle, fn _, acc ->
        assert {:ok, acc} = ChatThrottle.record(acc, 10)
        acc
      end)

    assert {:spam, _} = ChatThrottle.record(throttle, 10)
  end

  test "one message per tick is sustainable indefinitely" do
    final =
      Enum.reduce(0..2_000, ChatThrottle.new(0), fn tick, acc ->
        # 20 per message, minus one per tick: one message every 20 ticks is steady state.
        if rem(tick, 20) == 0 do
          assert {:ok, acc} = ChatThrottle.record(acc, tick * 50)
          acc
        else
          acc
        end
      end)

    assert final.count <= 20
  end
end
