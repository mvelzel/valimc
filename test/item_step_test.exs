defmodule Valimc.Physics.ItemStepTest do
  use ExUnit.Case, async: true
  alias Valimc.World.View
  alias Valimc.Entity.ItemMotionState
  alias Valimc.World.ItemStep

  defp frame(floor_state \\ 1) do
    View.of(
      for x <- -3..5,
          y <- 62..68,
          z <- -3..5,
          into: %{},
          do: {{x, y, z}, if(y == 63, do: floor_state, else: 0)}
    )
  end

  defp item(position \\ {0.5, 65.5, 0.5}, motion \\ %ItemMotionState{}),
    do: %{id: 7, position: position, motion: motion}

  test "missing and embedded geometry refuse rather than inventing air" do
    assert [{:error, {:missing_block, _}}] = ItemStep.run(View.of(%{}), [item()], nil)
    assert [{:error, :item_inside_block}] = ItemStep.run(frame(), [item({0.5, 63.5, 0.5})], nil)
  end

  test "a falling item lands on the floor and ages" do
    [{:ok, landed}] = ItemStep.run(frame(), [item({0.5, 64.01, 0.5})], nil)
    assert {0.5, 64.0, 0.5} == landed.position and landed.motion.on_ground
    assert landed.motion.age == 1 and landed.id == 7
  end
end
