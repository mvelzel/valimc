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

  test "an orb falls and drags, and is pulled toward the player it follows (VMC-077i)" do
    orb = %{
      id: 9,
      position: {0.5, 66.0, 0.5},
      motion: %ItemMotionState{velocity: {0.1, 0.0, 0.0}}
    }

    drag = 0.9800000190734863
    [{:ok, free}] = ItemStep.run_orbs(frame(), [orb], nil)
    assert free.position == {0.6, 65.97, 0.5}
    assert free.motion.velocity == {0.1 * drag, -0.03 * drag, 0.0}

    # Four blocks from its target the pull is (1 - 4/8)^2 * 0.1 = 0.025 toward it.
    resting = Map.merge(orb, %{motion: %ItemMotionState{}, target: {4.5, 66.0, 0.5}})
    [{:ok, pulled}] = ItemStep.run_orbs(frame(), [resting], nil)
    {vx, vy, 0.0} = pulled.motion.velocity
    assert_in_delta vx, 0.025 * drag, 1.0e-12
    assert_in_delta vy, -0.03 * drag, 1.0e-12
  end

  test "an orb landing faster than gravity bounces at four tenths" do
    orb = %{
      id: 9,
      position: {0.5, 64.1, 0.5},
      motion: %ItemMotionState{velocity: {0.0, -0.3, 0.0}}
    }

    [{:ok, landed}] = ItemStep.run_orbs(frame(), [orb], nil)
    assert landed.position == {0.5, 64.0, 0.5} and landed.motion.on_ground
    # The fall before the move was -0.33: the bounce is 0.4 of it.
    assert_in_delta elem(landed.motion.velocity, 1), 0.33 * 0.4, 1.0e-12
  end
end
