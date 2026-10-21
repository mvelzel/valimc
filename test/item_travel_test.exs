defmodule Valimc.Physics.ItemTravelTest do
  use ExUnit.Case, async: true
  alias Valimc.World.View
  alias Valimc.ItemMotionState
  alias Valimc.Physics.{ItemTravel}

  defp frame(floor_state \\ 1, extra \\ %{}) do
    states =
      for x <- -3..5,
          y <- 62..68,
          z <- -3..5,
          into: %{},
          do: {{x, y, z}, if(y == 63, do: floor_state, else: 0)}

    View.of(Map.merge(states, extra))
  end

  defp item(position \\ {0.5, 65.5, 0.5}, motion \\ %ItemMotionState{}),
    do: %{id: 7, revision: 1, position: position, motion: motion}

  test "missing/embedded geometry and invalid observations refuse rather than inventing air" do
    assert {:error, {:missing_block, _}} =
             ItemTravel.sample(item(), View.of(%{}))

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
