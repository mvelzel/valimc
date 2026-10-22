defmodule Valimc.GeneratorPoolTest do
  @moduledoc "Concurrent generations share the seed's context, in batches, with unchanged chunks (VMC-071, VMC-077n)."
  use ExUnit.Case, async: true
  alias Valimc.Protocol.Data
  alias Valimc.Worldgen.Generator

  @seed 70_071

  test "concurrent batched generation equals one call's chunks" do
    regions =
      for rx <- [-3, 5],
          rz <- [2],
          do: for(cx <- (rx * 8)..(rx * 8 + 3), cz <- (rz * 8)..(rz * 8 + 1), do: {cx, cz})

    pooled =
      regions
      |> Enum.map(fn chunks ->
        Task.async(fn -> Generator.columns({:vanilla, @seed}, chunks) end)
      end)
      |> Enum.map(&Task.await(&1, 60_000))
      |> Enum.reduce(&Map.merge/2)

    {:ok, state} = Valimc.Worldgen.new(@seed)

    biomes =
      Enum.map(Valimc.Worldgen.biome_names(), &Data.registry_id("minecraft:worldgen/biome", &1))

    {:ok, single} =
      Valimc.Native.worldgen_columns(state, "minecraft:overworld", biomes, List.flatten(regions))

    assert map_size(pooled) == 16
    assert pooled == Map.new(single, fn {cx, cz, image, _} -> {{cx, cz}, image} end)
  end
end
