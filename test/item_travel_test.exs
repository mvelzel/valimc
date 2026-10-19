defmodule Valimc.Physics.ItemTravelTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Physics.{BlockCollisions.Frame, ItemTravel}

  defp frame(floor_state \\ 1, extra \\ %{}) do
    states =
      for x <- -3..5,
          y <- 62..68,
          z <- -3..5,
          into: %{},
          do: {{x, y, z}, if(y == 63, do: floor_state, else: 0)}

    %Frame{states: Map.merge(states, extra), fences: %{}, entities: %{}}
  end

  defp item(position \\ {0.5, 65.5, 0.5}, motion \\ %ItemMotionState{}),
    do: %{id: 7, revision: 1, position: position, motion: motion}

  test "leaving an ice edge retains the old horizontal support for the accepted landing step" do
    f = frame(0, %{{0, 63, 0} => 8597})
    initial = item({0.9, 64.0, 0.5}, %ItemMotionState{velocity: {0.4, 0, 0}})
    assert {:ok, moved} = ItemTravel.sample(initial, f)
    assert moved.position == {1.3, 64.0, 0.5} and moved.motion.on_ground
    assert elem(moved.motion.velocity, 0) == 0.38416001796722415
  end

  test "owner-selected sleeping preserves sentinel age/delay and refresh wakes unsupported items" do
    initial =
      item({0.5, 65.5, 0.5}, %ItemMotionState{
        on_ground: true,
        age: -32_768,
        pickup_delay: 32_767
      })

    assert {:ok, sleeping} = ItemTravel.sample(initial, frame(), false)
    assert sleeping.position == initial.position
    assert sleeping.motion.age == -32_768 and sleeping.motion.pickup_delay == 32_767
    assert {:ok, awake} = ItemTravel.sample(sleeping, frame(), true)
    assert elem(awake.position, 1) < elem(initial.position, 1)
    refute awake.motion.on_ground
  end

  test "missing/embedded geometry and invalid observations refuse rather than inventing air" do
    assert {:error, {:missing_block, _}} =
             ItemTravel.sample(item(), %Frame{states: %{}, fences: %{}, entities: %{}})

    assert {:error, :item_inside_block} = ItemTravel.sample(item({0.5, 63.5, 0.5}), frame())
    assert {:error, :invalid_item_travel} = ItemTravel.query_box(item({0, 1_000_001, 0}))
    assert {:error, :invalid_item_travel} = ItemTravel.sample(%{}, frame())
    assert {:error, :invalid_item_travel} = ItemTravel.sample(item(), frame(), nil)

    assert {:error, :item_motion_limit} =
             ItemTravel.sample(
               item({0.5, 65.5, 0.5}, %ItemMotionState{velocity: {0, -64, 0}}),
               frame()
             )
  end
end
