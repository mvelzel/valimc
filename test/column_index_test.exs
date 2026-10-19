defmodule Valimc.ColumnIndexTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.Data
  alias Valimc.World.{Chunk, ColumnIndex}

  defp restore(edits), do: ColumnIndex.restore(edits, &Chunk.block_at(edits, &1))

  defp update(index, edits, changes),
    do: ColumnIndex.update(index, &Chunk.block_at(edits, &1), changes)

  test "native rain shelter distinguishes glass, fire, water and solid blocks" do
    column = {4, -3}
    position = {4, 80, -3}

    for {block, surface, motion, sky} <- [
          {Data.block("stone"), 81, 81, 81},
          {Data.block("glass"), 81, 81, 64},
          {4931, 81, 64, 64},
          {89, 81, 81, 81},
          {0, 64, 64, 64}
        ] do
      index = restore(%{position => block})

      assert ColumnIndex.heights(index, column) ==
               %{world_surface: surface, motion_blocking: motion, sky_source: sky}
    end
  end

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
end
