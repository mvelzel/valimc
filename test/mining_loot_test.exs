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

  test "ordinary mining admits finite deterministic cubes without specialized callbacks" do
    for name <-
          ~w(polished_granite spruce_planks iron_block red_concrete bookshelf obsidian packed_ice crafting_table) do
      state = Data.item_block(Data.item(name))
      assert MiningLoot.ordinary_mining?(state)
      assert {:ok, _} = MiningLoot.drops(state, nil, true)
    end

    for name <-
          ~w(bedrock melon gilded_blackstone glowstone sea_lantern oak_stairs chest diamond_ore) do
      refute MiningLoot.ordinary_mining?(Data.item_block(Data.item(name)))
    end

    for state <- [nil, -1, Data.block_state_count()],
        do: refute(MiningLoot.ordinary_mining?(state))

    assert {:ok, [books]} = MiningLoot.drops(Data.item_block(Data.item("bookshelf")), nil, true)
    assert books == ItemStack.new("book", 3)
  end

  test "pillar axes retain native self drops and deepslate's independent Silk Touch branch" do
    silk = %{
      ItemStack.new("diamond_pickaxe")
      | components: %{"minecraft:enchantments" => %{"minecraft:silk_touch" => 1}}
    }

    for state <- [139, 140, 141] do
      assert MiningLoot.ordinary_mining?(state)
      assert MiningLoot.drops(state, nil, true) == {:ok, [ItemStack.new("oak_log")]}
    end

    for state <- [33773, 33774, 33775] do
      assert MiningLoot.ordinary_mining?(state)
      assert MiningLoot.drops(state, nil, true) == {:ok, [ItemStack.new("cobbled_deepslate")]}
      assert MiningLoot.drops(state, silk, true) == {:ok, [ItemStack.new("deepslate")]}
    end
  end
end
