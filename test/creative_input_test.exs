defmodule Valimc.CreativeInputTest do
  use ExUnit.Case, async: true
  alias Valimc.CreativeInput

  test "strict vanilla threshold permits 74 requests, then admits 1479 up to 1499" do
    full =
      Enum.reduce(1..74, CreativeInput.new(10), fn _, input ->
        assert {:ok, next} = CreativeInput.charge(input, 10)
        next
      end)

    assert full.level == 1480
    assert {:throttled, ^full} = CreativeInput.charge(full, 10)
    assert {:ok, after_tick} = CreativeInput.charge(full, 11)
    assert after_tick.level == 1499
    assert {:throttled, boundary} = CreativeInput.charge(after_tick, 30)
    assert boundary.level == 1480
    assert {:ok, admitted} = CreativeInput.charge(boundary, 31)
    assert admitted.level == 1499
    assert {:throttled, ^admitted} = CreativeInput.charge(admitted, 0)
    assert {:ok, idle} = CreativeInput.charge(admitted, 10_000)
    assert idle.level == 20
  end

  test "FIFO queue bounds command count and releases exactly each charged cost" do
    queue =
      Enum.reduce(1..160, CreativeInput.new(0), fn n, queue ->
        assert {:ok, next} = CreativeInput.push(queue, {:slot, n}, 3)
        next
      end)

    assert queue.queued == 160 and queue.bytes == 160 * 67
    assert {:error, :creative_queue_limit} = CreativeInput.push(queue, :extra, 0)

    empty =
      Enum.reduce(1..160, queue, fn n, queue ->
        assert {:ok, {:slot, ^n}, next} = CreativeInput.pop(queue)
        next
      end)

    assert empty.queued == 0 and empty.bytes == 0 and CreativeInput.pop(empty) == :empty
  end

  test "encoded byte cap rejects whole commands and clear never resets throttle credit" do
    assert {:ok, charged} = CreativeInput.charge(CreativeInput.new(0), 0)
    assert {:ok, queue} = CreativeInput.push(charged, :large, 524_288 - 64)
    assert queue.queued == 1 and queue.bytes == 524_288
    assert {:error, :creative_queue_limit} = CreativeInput.push(queue, :extra, 0)
    empty = CreativeInput.clear(queue)
    assert empty.level == 20 and empty.tick == 0 and empty.queued == 0 and empty.bytes == 0
  end
end
