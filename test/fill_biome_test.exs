defmodule Valimc.FillBiomeTest do
  use ExUnit.Case, async: true
  # `/fillbiome`'s resolver (VMC-053j4), vanilla's `FillBiomeCommand.makeResolver`:
  # cells whose corner block lies in the quantized box and pass the filter.
  alias Valimc.World.Blocks
  alias Valimc.Protocol.Data

  defp id(name), do: Data.registry_id("minecraft:worldgen/biome", name)

  test "cells inside the box change, once, and filters keep the rest" do
    {:ok, blocks} = Blocks.new({0, 0})
    desert = id("minecraft:desert")
    forest = id("minecraft:forest")

    # 0..4 on each axis: two cells per axis, eight in all.
    assert {:ok, {8, [{0, 0, image}]}} =
             Blocks.fill_biomes(blocks, [{0, 0}], {{0, 64, 0}, {4, 68, 4}}, desert, nil)

    assert is_binary(image)

    assert {:ok, {0, []}} =
             Blocks.fill_biomes(blocks, [{0, 0}], {{0, 64, 0}, {4, 68, 4}}, desert, nil)

    # Only the cells that are still plains, a 3 × 2 × 3 box minus the 2 × 2 × 2 desert.
    assert {:ok, {10, [_]}} =
             Blocks.fill_biomes(
               blocks,
               [{0, 0}],
               {{0, 64, 0}, {8, 68, 8}},
               forest,
               [id("minecraft:plains")]
             )

    {:ok, bytes} = Blocks.encode_biomes(blocks, {0, 0})
    assert byte_size(bytes) > 24
  end
end
