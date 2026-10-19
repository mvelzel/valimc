defmodule Valimc.ArmorDurabilityTest do
  use ExUnit.Case, async: true
  alias Valimc.{ArmorDurability, Inventory}
  alias Valimc.Protocol.ItemStack

  test "source, permission, component and netherite resistance gates preserve inventory without RNG" do
    helmet = ItemStack.new("iron_helmet")
    inventory = %Inventory{slots: %{5 => helmet, 36 => helmet}, carried: helmet}
    no_draw = fn -> flunk("Unexpected armor RNG") end
    assert {:ok, ^inventory, []} = ArmorDurability.damage(inventory, :on_fire, 1, false, no_draw)
    assert {:ok, ^inventory, []} = ArmorDurability.damage(inventory, :lava, 4, true, no_draw)
    assert {:ok, ^inventory, []} = ArmorDurability.damage(inventory, :lava, 0, false, no_draw)
    assert {:ok, worn, []} = ArmorDurability.damage(inventory, :lava, 4, false, no_draw)
    assert worn.slots[5].components["minecraft:damage"] == 1
    assert worn.slots[36] == helmet and worn.carried == helmet

    for removed <- ["minecraft:equippable", "minecraft:damage", "minecraft:max_damage"] do
      inventory = %Inventory{slots: %{5 => %{helmet | removed: MapSet.new([removed])}}}
      assert {:ok, ^inventory, []} = ArmorDurability.damage(inventory, :lava, 4, false, no_draw)
    end

    boots = ItemStack.new("netherite_boots")
    inventory = %Inventory{slots: %{8 => boots}}
    assert {:ok, ^inventory, []} = ArmorDurability.damage(inventory, :lava, 4, false, no_draw)
    vulnerable = %{boots | removed: MapSet.new(["minecraft:damage_resistant"])}

    assert {:ok, worn, []} =
             ArmorDurability.damage(
               %Inventory{slots: %{8 => vulnerable}},
               :lava,
               4,
               false,
               no_draw
             )

    assert worn.slots[8].components["minecraft:damage"] == 1
    assert {:error, :invalid_armor_wear} = ArmorDurability.damage(inventory, :lava, 5, false)
  end

  test "armor Unbreaking uses its native threshold; breaks carry the worn stack and retain other slots" do
    helmet = %{
      ItemStack.new("iron_helmet")
      | components: %{
          "minecraft:damage" => 164,
          "minecraft:enchantments" => %{"minecraft:unbreaking" => 1}
        }
    }

    inventory = %Inventory{slots: %{5 => helmet, 8 => helmet}}
    draws = [0.19999998807907104, 0.20000000298023224]
    Process.put(:draws, draws)

    random = fn ->
      [value | rest] = Process.get(:draws)
      Process.put(:draws, rest)
      value
    end

    assert {:ok, worn, [{5, broken}]} = ArmorDurability.damage(inventory, :lava, 4, false, random)
    assert broken.components["minecraft:damage"] == 165
    assert worn.slots == %{8 => helmet} and Process.get(:draws) == []

    huge = %{
      helmet
      | components: %{
          "minecraft:max_damage" => 2_147_483_647,
          "minecraft:damage" => 2_147_483_647
        }
    }

    assert {:ok, worn, []} =
             ArmorDurability.damage(%Inventory{slots: %{5 => huge}}, :in_fire, 1, false)

    assert worn.slots[5].components["minecraft:damage"] == 0
  end
end
