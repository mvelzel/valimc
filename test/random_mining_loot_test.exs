defmodule Valimc.Physics.RandomMiningLootTest do
  use ExUnit.Case, async: true
  alias Valimc.Physics.{MiningLoot, RandomMiningLoot}
  alias Valimc.Protocol.{Data, ItemStack}

  defp block(name), do: Data.item_block(Data.item(name))

  defp enchanted(levels, component \\ "minecraft:enchantments"),
    do: %{ItemStack.new("diamond_pickaxe") | components: %{component => levels}}

  test "bounded uniform counts and Fortune caps retain Silk Touch and wrong-harvest gates" do
    for {name, drop, low, high, cap} <- [
          {"melon", "melon_slice", 3, 7, 9},
          {"glowstone", "glowstone_dust", 2, 4, 4},
          {"sea_lantern", "prismarine_crystals", 2, 3, 5}
        ] do
      state = block(name)
      assert RandomMiningLoot.supported?(state)

      assert RandomMiningLoot.drops(state, nil, true, fn _ -> 0 end) ==
               {:ok, [ItemStack.new(drop, low)]}

      assert RandomMiningLoot.drops(state, nil, true, fn bound -> bound - 1 end) ==
               {:ok, [ItemStack.new(drop, high)]}

      fortune = enchanted(%{"minecraft:fortune" => 255})

      assert RandomMiningLoot.drops(state, fortune, true, fn bound -> bound - 1 end) ==
               {:ok, [ItemStack.new(drop, cap)]}

      stored = enchanted(%{"minecraft:fortune" => 255}, "minecraft:stored_enchantments")

      assert RandomMiningLoot.drops(state, stored, true, fn bound -> bound - 1 end) ==
               {:ok, [ItemStack.new(drop, high)]}

      silk = enchanted(%{"minecraft:fortune" => 255, "minecraft:silk_touch" => 1})

      assert RandomMiningLoot.drops(state, silk, true, fn _ -> flunk("Silk RNG") end) ==
               {:ok, [ItemStack.new(name)]}

      assert RandomMiningLoot.drops(state, fortune, false, fn _ -> flunk("Wrong-harvest RNG") end) ==
               {:ok, []}

      assert {:ok, [sampled]} = MiningLoot.drops(state, nil, true)
      assert sampled.item_id == Data.item(drop) and sampled.count in low..high
    end
  end

  test "gilded blackstone chance compares native floats strictly and saturates the Fortune table" do
    state = block("gilded_blackstone")

    for {level, chance, below} <- [
          {0, 0.10000000149011612, 0.09999999403953552},
          {1, 0.1428571492433548, 0.1428571343421936},
          {2, 0.25, 0.2499999850988388}
        ] do
      pick = enchanted(%{"minecraft:fortune" => level})

      assert RandomMiningLoot.drops(state, pick, true, fn
               :float -> below
               bound -> bound - 1
             end) == {:ok, [ItemStack.new("gold_nugget", 5)]}

      assert RandomMiningLoot.drops(state, pick, true, fn :float -> chance end) ==
               {:ok, [ItemStack.new("gilded_blackstone")]}
    end

    for level <- [3, 4, 255] do
      assert RandomMiningLoot.drops(state, enchanted(%{"minecraft:fortune" => level}), true, fn
               :float -> 0.9999999403953552
               _ -> 0
             end) == {:ok, [ItemStack.new("gold_nugget", 2)]}
    end

    for state <- [nil, -1, Data.block_state_count(), block("diamond_ore"), block("bedrock")] do
      refute RandomMiningLoot.supported?(state)
      assert RandomMiningLoot.drops(state, nil, true) == {:error, :unsupported_mining_loot}
    end
  end
end
