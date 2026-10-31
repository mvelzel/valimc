defmodule Valimc.EnchantmentEffectsTest do
  # The engine's hooks are compared with vanilla's by the `enchantment_effects`
  # stage; these tests cover how players apply them (VMC-037q).
  use ExUnit.Case, async: true
  alias Valimc.Blocks.MiningLoot
  alias Valimc.Living.Armor
  alias Valimc.Menus.Inventory
  alias Valimc.Player.{Items, MiningSpeed}
  alias Valimc.Protocol.{Data, ItemStack}

  defp enchanted(name, enchantments, components \\ %{}) do
    stack = ItemStack.new(name)

    %{
      stack
      | components: Map.merge(components, %{"minecraft:enchantments" => Map.new(enchantments)})
    }
  end

  test "Efficiency, Aqua Affinity and Depth Strider act through their attributes" do
    inventory = %{
      Inventory.new()
      | slots: %{
          36 => enchanted("diamond_pickaxe", [{"minecraft:efficiency", 5}]),
          5 => enchanted("iron_helmet", [{"minecraft:aqua_affinity", 1}])
        }
    }

    assert %{mining_efficiency: 26.0, submerged_mining_speed: 1.0} =
             MiningSpeed.attributes(inventory)

    boots = enchanted("iron_boots", [{"minecraft:depth_strider", 3}])

    assert Armor.enchanted_value(
             Armor.attributes(%{feet: boots}),
             "minecraft:water_movement_efficiency"
           ) == 1.0
  end

  test "Silk Touch keeps an ore's experience; a spawner's is its own" do
    pickaxe = enchanted("diamond_pickaxe", [{"minecraft:silk_touch", 1}])
    assert MiningLoot.experience(Data.block("diamond_ore"), pickaxe) == 0
    assert MiningLoot.experience(Data.block("diamond_ore"), ItemStack.new("diamond_pickaxe")) > 0
    assert MiningLoot.experience(Data.block("spawner"), pickaxe) > 0
  end

  test "Mending repairs a damaged item with an orb's experience, twice its value" do
    boots = enchanted("iron_boots", [{"minecraft:mending", 1}], %{"minecraft:damage" => 5})
    inventory = %{Inventory.new() | slots: %{8 => boots}}

    {inventory, left} = Items.mend(inventory, 2)
    assert left == 0
    assert inventory.slots[8].components["minecraft:damage"] == 1

    # 7 points mend the last point with 1 and keep 6.
    {inventory, left} = Items.mend(inventory, 7)
    assert inventory.slots[8].components["minecraft:damage"] == 0
    assert left == 7 - div(1 * 7, 14)

    assert {^inventory, 3} = Items.mend(inventory, 3)
  end

  test "Curse of Binding keeps worn armour out of a survival player's hands" do
    alias Valimc.Menus.{Click, Menu}
    cursed = enchanted("iron_chestplate", [{"minecraft:binding_curse", 1}])
    inventory = %{Inventory.new() | slots: %{6 => cursed}}

    for action <- [:pickup, :quick_move, :throw] do
      assert {:ok, nil, %{slots: %{6 => ^cursed}}, []} =
               Click.plan(Menu.inventory(), nil, inventory, action, 6, 0)
    end

    assert {:ok, nil, %{slots: slots, carried: ^cursed}, []} =
             Click.plan(
               Menu.inventory(),
               nil,
               %{inventory | infinite_materials: true},
               :pickup,
               6,
               0
             )

    refute Map.has_key?(slots, 6)
  end
end
