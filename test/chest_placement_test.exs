defmodule Valimc.Physics.ChestPlacementTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.ChestPlacement
  alias Valimc.Protocol.Data

  test "cardinal and boundary orientation use native floor-to-int behavior" do
    for {yaw, direction} <- [
          {-45.000004, 5},
          {-45.0, 3},
          {44.999996, 3},
          {45.0, 4},
          {135.0, 2},
          {225.0, 5},
          {315.0, 3},
          {-3.4028234663852886e38, 3},
          {3.4028234663852886e38, 5}
        ] do
      assert {:ok, ^direction} = ChestPlacement.horizontal(yaw)
    end

    for invalid <- [nil, :north, 1.0e39],
        do: assert({:error, :invalid_chest_yaw} = ChestPlacement.horizontal(invalid))
  end

  test "isolated state retains only source water and does not claim target replaceability" do
    assert {:ok, dry} = ChestPlacement.single_state(0.0, 0)
    assert {:ok, wet} = ChestPlacement.single_state(0.0, 89)
    assert dry != wet
    assert Valimc.ChestAccess.single?(dry) and Valimc.ChestAccess.single?(wet)
    assert {:ok, ^dry} = ChestPlacement.single_state(0.0, 90)
    assert {:ok, ^dry} = ChestPlacement.single_state(0.0, 105)
    assert {:ok, ^dry} = ChestPlacement.single_state(0.0, Data.block("stone"))
    assert {:error, :unknown_block_state} = ChestPlacement.single_state(0.0, 35_723)
  end
end
