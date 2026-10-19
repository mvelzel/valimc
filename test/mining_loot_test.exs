defmodule Valimc.Physics.MiningLootTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.MiningLoot
  alias Valimc.Protocol.{Data, ItemStack}

  test "unsupported random/context families never become guessed drops" do
    ore = Data.item_block(Data.item("diamond_ore"))
    assert {:error, :unsupported_mining_loot} = MiningLoot.drops(ore, nil, true)
    assert {:ok, []} = MiningLoot.drops(ore, nil, false)
    assert {:ok, [planks]} = MiningLoot.drops(Data.block("oak_planks"), nil, true)
    assert planks == ItemStack.new("oak_planks")

    for state <- [-1, Data.block_state_count(), nil],
        do: assert({:error, :invalid_mining_loot} == MiningLoot.drops(state, nil, true))
  end

  test "single stock chests drop themselves independently of facing, water and enchantments" do
    facts = JSON.decode!(File.read!("priv/protocol/chest_states.json"))

    tool = %{
      ItemStack.new("diamond_axe")
      | components: %{"minecraft:enchantments" => %{"minecraft:fortune" => 255}}
    }

    for state <- facts["single_states"], tool <- [nil, tool] do
      assert MiningLoot.drops(state, tool, true) == {:ok, [ItemStack.new("chest")]}
      assert MiningLoot.drops(state, tool, false) == {:ok, []}
    end

    for row <- facts["states"],
        row["state"] not in facts["single_states"],
        do:
          assert(MiningLoot.drops(row["state"], nil, true) == {:error, :unsupported_mining_loot})
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
