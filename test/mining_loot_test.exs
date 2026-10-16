defmodule Valimc.Physics.MiningLootTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.MiningLoot
  alias Valimc.Protocol.{Data, ItemStack}

  test "deterministic drops honor direct Silk Touch with the original final-use tool" do
    tool = %{
      ItemStack.new("iron_pickaxe")
      | components: %{
          "minecraft:enchantments" => %{"minecraft:silk_touch" => 1},
          "minecraft:damage" => 249
        }
    }

    assert {:ok, [stone]} = MiningLoot.drops(Data.block("stone"), tool, true)
    assert stone == ItemStack.new("stone")
    assert {:ok, [cobble]} = MiningLoot.drops(Data.block("stone"), nil, true)
    assert cobble == ItemStack.new("cobblestone")

    stored = %{
      tool
      | components: %{"minecraft:stored_enchantments" => %{"minecraft:silk_touch" => 255}}
    }

    assert {:ok, [^cobble]} = MiningLoot.drops(Data.block("stone"), stored, true)
    assert {:ok, []} = MiningLoot.drops(Data.block("stone"), tool, false)
    assert {:ok, []} = MiningLoot.drops(Data.block("glass"), nil, true)
    assert {:ok, [glass]} = MiningLoot.drops(Data.block("glass"), tool, true)
    assert glass == ItemStack.new("glass")
  end

  test "unsupported random/context families never become guessed drops" do
    ore = Data.item_block(Data.item("diamond_ore"))
    assert {:error, :unsupported_mining_loot} = MiningLoot.drops(ore, nil, true)
    assert {:ok, []} = MiningLoot.drops(ore, nil, false)
    assert {:ok, [planks]} = MiningLoot.drops(Data.block("oak_planks"), nil, true)
    assert planks == ItemStack.new("oak_planks")

    for state <- [-1, Data.block_state_count(), nil],
        do: assert({:error, :invalid_mining_loot} == MiningLoot.drops(state, nil, true))
  end

  test "single and double slab states retain exact counts independently of contained water" do
    for state <- 15177..15180,
        do: assert(MiningLoot.drops(state, nil, true) == {:ok, [ItemStack.new("oak_slab")]})

    for state <- 15181..15182,
        do: assert(MiningLoot.drops(state, nil, true) == {:ok, [ItemStack.new("oak_slab", 2)]})

    assert MiningLoot.drops(15181, nil, false) == {:ok, []}
  end
end
