defmodule Valimc.LootTest do
  use ExUnit.Case, async: true
  alias Valimc.Loot
  alias Valimc.Protocol.{ItemData, ItemStack}

  defp slots(fill),
    do:
      for(
        {stack, slot} <- fill |> Tuple.to_list() |> Enum.with_index(),
        stack,
        do: {slot, ItemData.tag(stack) |> elem(1) |> Map.fetch!("id") |> elem(1), stack.count}
      )

  test "a dungeon chest fills as vanilla's LootTable.fill does for its stored seed" do
    origin = {218, -8, 595}

    assert {:ok, fill, 0} =
             Loot.fill("minecraft:chests/simple_dungeon", 5_530_731_629_134_945_404, origin)

    assert tuple_size(fill) == 27

    assert slots(fill) == [
             {0, "minecraft:enchanted_golden_apple", 1},
             {1, "minecraft:wheat", 2},
             {2, "minecraft:rotten_flesh", 5},
             {4, "minecraft:rotten_flesh", 5},
             {5, "minecraft:rotten_flesh", 3},
             {6, "minecraft:coal", 2},
             {11, "minecraft:wheat", 2},
             {12, "minecraft:bucket", 1},
             {14, "minecraft:leather", 2},
             {15, "minecraft:gunpowder", 2},
             {18, "minecraft:bread", 1},
             {19, "minecraft:rotten_flesh", 2},
             {20, "minecraft:coal", 2},
             {21, "minecraft:leather", 1},
             {22, "minecraft:gunpowder", 1},
             {25, "minecraft:gunpowder", 1}
           ]

    assert Loot.fill("minecraft:chests/simple_dungeon", 5_530_731_629_134_945_404, origin) ==
             {:ok, fill, 0}
  end

  test "a stored seed of zero rolls a fresh seed" do
    fills =
      for _ <- 1..8 do
        {:ok, fill, 0} = Loot.fill("minecraft:chests/simple_dungeon", 0, {0, 64, 0})
        fill
      end

    assert length(Enum.uniq(fills)) > 1
  end

  test "an exploration map takes the next map id and marks the structure it finds" do
    assert {:ok, fill, 1} =
             Loot.fill(
               "minecraft:chests/shipwreck_map",
               2_520_033_817_095_647_977,
               {291, 232, 401},
               biome: "minecraft:plains",
               structure: {-53, 64, -3}
             )

    [map] =
      fill |> Tuple.to_list() |> Enum.filter(&(&1 && ItemStack.component(&1, "minecraft:map_id")))

    assert ItemStack.component(map, "minecraft:map_id") == 0

    assert ItemStack.component(map, "minecraft:map_decorations") == [
             {"+", "minecraft:red_x", -53.0, -3.0, 180.0}
           ]

    # Persistent only: the decorations never reach the network, the map id does.
    assert {:ok, sent} = map |> ItemStack.encode() |> IO.iodata_to_binary() |> ItemStack.decode()
    assert sent.components == Map.delete(map.components, "minecraft:map_decorations")
    assert ItemData.stack(ItemData.tag(map)) == {:ok, map}
  end

  test "a table that names no structure search finds still fills, and unknown tables fail" do
    assert {:ok, items, 0} = Loot.items("minecraft:archaeology/desert_pyramid", 7, {0, 64, 0})
    assert [%ItemStack{count: 1}] = items
    assert {:error, _} = Loot.fill("minecraft:chests/nonexistent", 1, {0, 64, 0})
  end

  test "loot components round-trip through the network and the data format" do
    stacks = [
      %{
        ItemStack.new("suspicious_stew")
        | components: %{
            "minecraft:suspicious_stew_effects" => [
              {"minecraft:weakness", 140},
              {"minecraft:night_vision", 160}
            ]
          }
      },
      %{
        ItemStack.new("goat_horn")
        | components: %{"minecraft:instrument" => "minecraft:yearn_goat_horn"}
      },
      %{
        ItemStack.new("ominous_bottle")
        | components: %{"minecraft:ominous_bottle_amplifier" => 3}
      }
    ]

    for stack <- stacks do
      assert {:ok, ^stack} =
               stack |> ItemStack.encode() |> IO.iodata_to_binary() |> ItemStack.decode()

      assert ItemData.stack(ItemData.tag(stack)) == {:ok, stack}
    end

    # A default stew duration is left out of the saved entry.
    {:compound, %{"components" => {:compound, components}}} = ItemData.tag(hd(stacks))

    assert {:list, {:compound, [%{"duration" => {:int, 140}}, night_vision]}} =
             components["minecraft:suspicious_stew_effects"]

    refute Map.has_key?(night_vision, "duration")
  end

  test "values equal to an item's defaults leave no patch" do
    horn = %{
      ItemStack.new("goat_horn")
      | components: %{"minecraft:instrument" => "minecraft:ponder_goat_horn"}
    }

    bottle = %{
      ItemStack.new("ominous_bottle")
      | components: %{"minecraft:ominous_bottle_amplifier" => 0}
    }

    assert ItemStack.normalize(horn) == ItemStack.new("goat_horn")
    assert ItemStack.normalize(bottle) == ItemStack.new("ominous_bottle")

    assert ItemStack.component(ItemStack.new("goat_horn"), "minecraft:instrument") ==
             "minecraft:ponder_goat_horn"
  end
end
