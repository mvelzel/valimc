defmodule Valimc.PlayerArmorTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerArmor, Protocol.ItemStack}

  test "worn netherite contributes while storage, carried and the wrong equipment slot do not" do
    slots =
      Map.new(
        [
          {5, "netherite_helmet"},
          {6, "netherite_chestplate"},
          {7, "netherite_leggings"},
          {8, "netherite_boots"}
        ],
        fn {slot, name} -> {slot, ItemStack.new(name)} end
      )

    assert PlayerArmor.attributes(%Inventory{slots: slots}) == %{
             armor: 20,
             toughness: 12.0,
             burning_time: 1.0
           }

    assert PlayerArmor.attributes(%Inventory{
             slots: %{9 => slots[6], 5 => slots[8]},
             carried: slots[7]
           }) == %{armor: 0, toughness: 0.0, burning_time: 1.0}
  end

  test "removing stock attribute modifiers preserves independent fire protection" do
    stack = %{
      ItemStack.new("netherite_chestplate")
      | removed: MapSet.new(["minecraft:attribute_modifiers"]),
        components: %{"minecraft:enchantments" => %{"minecraft:fire_protection" => 4}}
    }

    attrs = PlayerArmor.attributes(%Inventory{slots: %{6 => stack}})
    assert attrs.armor == 0 and attrs.toughness == 0.0 and attrs.burning_time < 0.5

    assert PlayerArmor.attributes(%Inventory{slots: %{36 => stack, 45 => stack}}).burning_time ==
             1.0
  end

  test "stored enchants have no effect and stacking clamps burning time at zero" do
    stored = %{
      ItemStack.new("stone")
      | components: %{"minecraft:stored_enchantments" => %{"minecraft:fire_protection" => 255}}
    }

    direct = %{
      stored
      | components: %{"minecraft:enchantments" => %{"minecraft:fire_protection" => 4}}
    }

    assert PlayerArmor.attributes(%Inventory{slots: %{5 => stored}}).burning_time == 1.0

    assert PlayerArmor.attributes(%Inventory{slots: %{5 => direct, 6 => direct}}).burning_time ==
             0.0
  end
end
