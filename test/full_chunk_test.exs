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
      state: Valimc.Data.Blocks.default_state(block),
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

defmodule Valimc.FullChunkEntitiesTest do
  @moduledoc """
  The entities generation added (VMC-042b) become body records of any type:
  a template's villager keeps its NBT and persistence, a mineshaft's chest
  minecart its loot, a frame faces its wall, a shulker's random yaw is drawn.
  """
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Worldgen.FullChunk

  defp entity(kind, nbt, persistent, yaw \\ 0.0),
    do: %{
      kind: kind,
      position: {1.5, 64.0, 2.5},
      yaw: yaw,
      nbt: nbt,
      persistent: persistent,
      rides: false
    }

  test "generated entities of every type are kept with what generation gave them" do
    villager =
      ~s({PersistenceRequired:1b,VillagerData:{profession:"minecraft:cleric"},id:"minecraft:villager"})

    loot = ~s({LootTable:"minecraft:chests/abandoned_mineshaft",LootTableSeed:7L})

    records =
      FullChunk.entity_records([
        %{
          entities: [
            entity("minecraft:villager", villager, true),
            entity("minecraft:chest_minecart", loot, false),
            entity("minecraft:item_frame", nil, false, 90.0),
            entity("minecraft:shulker", nil, false, nil)
          ]
        }
      ])

    assert [villager_record, cart, frame, shulker] = records

    {:ok, store} = Store.restore({0, 0}, records)
    assert map_size(store.entries) == 4

    {:ok, body} = Body.restore(villager_record)

    assert body.type == "minecraft:villager" and body.mob.persistent and
             body.preserved == villager

    assert cart.kind == :object and cart.preserved == loot
    {:ok, frame} = Body.restore(frame)
    # West: the 3D value of a frame turned 90°.
    assert Body.spawn_data(frame) == 4
    {yaw, _, _} = shulker.rotation
    assert yaw >= 0.0 and yaw < 360.0
  end
end
