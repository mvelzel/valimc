defmodule Valimc.PlayerEnchantmentImmunityTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerEnchantmentImmunity}
  alias Valimc.Protocol.ItemStack

  test "direct Frost Walker presence in feet grants stepping immunity even at encoded level zero" do
    for item <- ["stone", "iron_boots"], level <- [0, 1, 2, 255] do
      stack = %{
        ItemStack.new(item)
        | components: %{"minecraft:enchantments" => %{"minecraft:frost_walker" => level}}
      }

      inventory = %Inventory{slots: %{8 => stack}}

      for source <- [:hot_floor, :campfire, :sulfur_cube_hot] do
        assert PlayerEnchantmentImmunity.immune?(inventory, source)
      end

      for source <- [:lava, :in_fire, :on_fire, :cactus, :sweet_berry_bush, :out_of_world] do
        refute PlayerEnchantmentImmunity.immune?(inventory, source)
      end
    end
  end

  test "carried, hand, other armor, stored and reduction enchantments grant no immunity" do
    stack = %{
      ItemStack.new("iron_boots")
      | components: %{"minecraft:enchantments" => %{"minecraft:frost_walker" => 2}}
    }

    for slot <- [1, 5, 6, 7, 9, 36, 45] do
      refute PlayerEnchantmentImmunity.immune?(
               %Inventory{slots: %{slot => stack}, carried: stack},
               :hot_floor
             )
    end

    for components <- [
          %{},
          %{"minecraft:stored_enchantments" => %{"minecraft:frost_walker" => 255}},
          %{"minecraft:enchantments" => %{"minecraft:fire_protection" => 255}}
        ] do
      refute PlayerEnchantmentImmunity.immune?(
               %Inventory{slots: %{8 => %{stack | components: components}}},
               :campfire
             )
    end

    refute PlayerEnchantmentImmunity.immune?(%Inventory{}, :hot_floor)
  end
end
