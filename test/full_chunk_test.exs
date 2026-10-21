defmodule Valimc.FullChunkTest do
  @moduledoc """
  Structure templates' block entities in the region store's parts (VMC-025f5):
  a village's empty smoker is the block's fresh block entity (it once stopped
  its chunks from generating), one with contents and a loot chest stay as
  data.
  """
  use ExUnit.Case, async: true
  alias Valimc.Worldgen.FullChunk

  @smoker ~s({Items:[],RecipesUsed:{},cooking_time_spent:0s,cooking_total_time:0s,id:"minecraft:smoker",lit_time_remaining:0s,lit_total_time:0s})

  defp entity(block, kind, nbt, loot \\ nil) do
    %{
      position: {1, 64, 2},
      state: Valimc.Registry.Blocks.default_state(block),
      kind: kind,
      nbt: nbt,
      loot_table: loot,
      loot_seed: if(loot, do: 7, else: 0),
      spawner_entity: nil,
      bees: [],
      exit: nil
    }
  end

  defp parts(entity) do
    chunk = %{
      x: 0,
      z: 0,
      image: <<>>,
      marks: [],
      fluid_ticks: [],
      block_ticks: [],
      block_entities: [entity]
    }

    FullChunk.parts([chunk], %{}, [])
  end

  test "empty template containers are the blocks' fresh block entities" do
    assert {:ok, %{block_entities: entities}} =
             parts(entity("smoker", "minecraft:smoker", @smoker))

    assert entities == %{}

    assert {:ok, %{block_entities: entities}} =
             parts(entity("chest", "minecraft:chest", ~s({Items:[],id:"minecraft:chest"})))

    assert entities == %{}
  end

  test "a lit template smoker and a loot chest stay as data" do
    lit = String.replace(@smoker, "lit_time_remaining:0s", "lit_time_remaining:20s")

    assert {:ok, %{block_entities: %{{1, 64, 2} => {_, _}}}} =
             parts(entity("smoker", "minecraft:smoker", lit))

    loot =
      entity(
        "chest",
        "minecraft:chest",
        ~s({id:"minecraft:chest"}),
        "minecraft:chests/village/village_butcher"
      )

    assert {:ok, %{block_entities: %{{1, 64, 2} => {_, _}}}} = parts(loot)
  end
end
