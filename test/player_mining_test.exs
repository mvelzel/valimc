defmodule Valimc.PlayerMiningTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerMining}
  alias Valimc.Protocol.{Data, ItemStack}

  test "selected main-hand efficiency requires a fast tool and independently retains harvest tier" do
    enchanted = %{
      ItemStack.new("iron_pickaxe")
      | components: %{"minecraft:enchantments" => %{"minecraft:efficiency" => 5}}
    }

    inventory = %Inventory{
      selected: 7,
      slots: %{43 => enchanted, 36 => ItemStack.new("diamond_pickaxe")}
    }

    assert PlayerMining.speed(inventory, Data.block("stone"), false, true) == 32.0
    assert PlayerMining.speed(inventory, Data.block("dirt"), false, true) == 1.0
    refute PlayerMining.harvest?(inventory, Data.item_block(Data.item("obsidian")))
    assert PlayerMining.harvest?(%Inventory{}, Data.block("dirt"))
    refute PlayerMining.harvest?(%Inventory{}, Data.block("stone"))

    stored = %{
      enchanted
      | components: %{"minecraft:stored_enchantments" => %{"minecraft:efficiency" => 255}}
    }

    assert PlayerMining.speed(
             %{inventory | slots: %{43 => stored}},
             Data.block("stone"),
             false,
             true
           ) == 6.0
  end

  test "eye submersion and airborne penalties compose with head-only bounded Aqua Affinity" do
    inventory = %Inventory{slots: %{36 => ItemStack.new("iron_pickaxe")}}
    <<wet::float-32>> = <<6.0 * 0.20000000298023224::float-32>>
    <<airborne::float-32>> = <<wet / 5.0::float-32>>
    assert PlayerMining.speed(inventory, Data.block("stone"), true, false) == airborne

    helmet = %{
      ItemStack.new("iron_helmet")
      | components: %{"minecraft:enchantments" => %{"minecraft:aqua_affinity" => 1}}
    }

    assert PlayerMining.speed(
             %{inventory | slots: Map.put(inventory.slots, 5, helmet)},
             Data.block("stone"),
             true,
             true
           ) == 6.0

    assert PlayerMining.speed(
             %{inventory | slots: Map.put(inventory.slots, 45, helmet)},
             Data.block("stone"),
             true,
             false
           ) == airborne

    helmet = %{
      helmet
      | components: %{"minecraft:enchantments" => %{"minecraft:aqua_affinity" => 255}}
    }

    assert PlayerMining.attributes(%{inventory | slots: Map.put(inventory.slots, 5, helmet)}).submerged_mining_speed ==
             20.0

    boosted = %Inventory{slots: %{36 => ItemStack.new("diamond_sword"), 5 => helmet}}
    bamboo = Data.item_block(Data.item("bamboo"))
    assert PlayerMining.speed(boosted, bamboo, true, false) == :infinity
    assert {:ok, :infinity} = PlayerMining.rate(boosted, bamboo, true, false)
    assert {:ok, +0.0} = Valimc.Physics.Mining.rate(Data.block("bedrock"), :infinity, true)
  end
end
