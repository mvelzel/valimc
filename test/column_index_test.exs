defmodule Valimc.ColumnIndexTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.Data
  alias Valimc.World.{Chunk, ColumnHeight, ColumnIndex}
  alias Valimc.Physics.HeightmapBlocks
  import Bitwise

  # Per-block heightmap and sky predicates are compared by the heightmap and
  # sky_column oracle stages.

  defp restore(edits), do: ColumnIndex.restore(edits, &Chunk.block_at(edits, &1))

  defp update(index, edits, changes),
    do: ColumnIndex.update(index, &Chunk.block_at(edits, &1), changes)

  test "batch neighbors and incremental edits rebuild to the same bounded words" do
    edits = %{{-1, 319, -1} => Data.block("stone"), {-1, 318, -1} => Data.block("glass")}
    index = restore(edits)
    assert ColumnIndex.heights(index, {-1, -1}).sky_source == 320
    edits = Map.delete(edits, {-1, 319, -1})
    index = update(index, edits, %{{-1, 319, -1} => 0})
    assert index == restore(edits)

    assert ColumnIndex.heights(index, {-1, -1}) ==
             %{world_surface: 319, motion_blocking: 319, sky_source: 64}

    index = update(index, %{}, %{{-1, 318, -1} => 0})
    assert index == %{}
  end

  test "empty base columns and restoration use the build minimum" do
    edits = for y <- -64..63, into: %{}, do: {{0, y, 0}, 0}
    index = restore(edits)

    assert ColumnIndex.heights(index, {0, 0}) ==
             %{world_surface: -64, motion_blocking: -64, sky_source: -64}

    restored = Map.new(edits, fn {{_, y, _} = position, _} -> {position, Chunk.base(y)} end)
    assert update(index, %{}, restored) == %{}
  end

  test "out-of-height persisted edits cannot alter column observations" do
    assert restore(%{{0, -65, 0} => 1, {0, 320, 0} => 1}) == %{}
  end

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
