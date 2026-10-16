defmodule Valimc.World.ColumnHeightTest do
  use ExUnit.Case, async: true
  alias Valimc.World.ColumnHeight
  alias Valimc.Physics.HeightmapBlocks
  import Bitwise

  test "highest removal reveals the prior column, including an empty world floor" do
    assert {:ok, 64} = ColumnHeight.height(ColumnHeight.flat())
    {:ok, roof} = ColumnHeight.update(ColumnHeight.flat(), 319, true)
    assert {:ok, 320} = ColumnHeight.height(roof)
    {:ok, restored} = ColumnHeight.update(roof, 319, false)
    assert restored == ColumnHeight.flat()

    empty =
      Enum.reduce(-64..63, restored, fn y, bits ->
        {:ok, bits} = ColumnHeight.update(bits, y, false)
        bits
      end)

    assert empty == ColumnHeight.empty()
    assert {:ok, -64} = ColumnHeight.height(empty)
    {:ok, bottom} = ColumnHeight.update(empty, -64, true)
    assert {:ok, -63} = ColumnHeight.height(bottom)
  end

  test "native predicates distinguish surface fire, fluids, stone and air" do
    assert {:ok, true} = HeightmapBlocks.opaque?(4931, :world_surface)
    assert {:ok, false} = HeightmapBlocks.opaque?(4931, :motion_blocking)
    assert {:ok, true} = HeightmapBlocks.opaque?(89, :motion_blocking)
    assert {:ok, false} = HeightmapBlocks.opaque?(89, :ocean_floor)
    assert {:ok, true} = HeightmapBlocks.opaque?(1, :ocean_floor)
    assert {:ok, 0} = HeightmapBlocks.mask(0)
  end

  test "column words and registry inputs have strict bounds" do
    for bits <- [-1, 1 <<< 384, nil, 1.0] do
      assert {:error, :invalid_column_height} = ColumnHeight.height(bits)
      assert {:error, :invalid_column_height} = ColumnHeight.update(bits, 64, true)
    end

    assert {:error, :invalid_column_height} = ColumnHeight.update(0, 320, true)
    assert {:error, :invalid_column_height} = ColumnHeight.update(0, -65, true)
    assert {:error, :invalid_column_height} = ColumnHeight.update(0, 64, nil)
    assert {:error, :unknown_block_state} = HeightmapBlocks.mask(35_723)
    assert {:error, :unknown_heightmap_type} = HeightmapBlocks.opaque?(0, :guessed)
  end
end
