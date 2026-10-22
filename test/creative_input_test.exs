defmodule Valimc.CreativeInputTest do
  use ExUnit.Case, async: true
  alias Valimc.Player.DropThrottle

  test "strict vanilla threshold permits 74 requests, then admits 1479 up to 1499" do
    full =
      Enum.reduce(1..74, DropThrottle.new(10), fn _, input ->
        assert {:ok, next} = DropThrottle.charge(input, 10)
        next
      end)

    assert full.level == 1480
    assert {:throttled, ^full} = DropThrottle.charge(full, 10)
    assert {:ok, after_tick} = DropThrottle.charge(full, 11)
    assert after_tick.level == 1499
    assert {:throttled, boundary} = DropThrottle.charge(after_tick, 30)
    assert boundary.level == 1480
    assert {:ok, admitted} = DropThrottle.charge(boundary, 31)
    assert admitted.level == 1499
    assert {:throttled, ^admitted} = DropThrottle.charge(admitted, 0)
    assert {:ok, idle} = DropThrottle.charge(admitted, 10_000)
    assert idle.level == 20
  end
end
