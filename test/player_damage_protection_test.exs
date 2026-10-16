defmodule Valimc.PlayerDamageProtectionTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerDamageProtection}
  alias Valimc.Protocol.ItemStack

  test "contact hazards use armor and ordinary protection; campfires additionally use fire protection" do
    gear = %{
      ItemStack.new("diamond_boots")
      | components: %{
          "minecraft:enchantments" => %{
            "minecraft:protection" => 1,
            "minecraft:fire_protection" => 2,
            "minecraft:feather_falling" => 255
          }
        }
    }

    inventory = %Inventory{slots: %{8 => gear}}
    assert PlayerDamageProtection.points(inventory, :campfire) == 5

    for source <- [:campfire, :cactus, :sweet_berry_bush] do
      assert PlayerDamageProtection.wears_armor?(source)
      assert PlayerDamageProtection.exhaustion(source) == 0.10000000149011612
      assert {:ok, damage} = PlayerDamageProtection.damage(inventory, source, 1)
      assert damage < 1
    end

    for source <- [:cactus, :sweet_berry_bush] do
      assert PlayerDamageProtection.points(inventory, source) == 1
    end
  end

  test "native worn slot rules include patched armor and exclude carried/stored/hand enchantments" do
    stack = %{
      ItemStack.new("iron_boots")
      | components: %{"minecraft:enchantments" => %{"minecraft:feather_falling" => 4}}
    }

    for slot <- 5..8 do
      assert PlayerDamageProtection.points(%Inventory{slots: %{slot => stack}}, :fall) == 12
      assert PlayerDamageProtection.points(%Inventory{slots: %{slot => stack}}, :freeze) == 0
    end

    for slot <- [1, 9, 36, 45] do
      assert PlayerDamageProtection.points(
               %Inventory{slots: %{slot => stack}, carried: stack},
               :fall
             ) == 0
    end

    stored = %{
      stack
      | components: %{"minecraft:stored_enchantments" => %{"minecraft:feather_falling" => 255}}
    }

    assert {:ok, 5.0} = PlayerDamageProtection.damage(%Inventory{slots: %{8 => stored}}, :fall, 5)
  end

  test "capped protection retains native float32 rounding, including the almost-fatal boundary" do
    stack = %{
      ItemStack.new("iron_boots")
      | components: %{
          "minecraft:enchantments" => %{
            "minecraft:protection" => 4,
            "minecraft:feather_falling" => 4
          }
        }
    }

    inventory = %Inventory{slots: Map.new(5..8, &{&1, stack})}
    assert PlayerDamageProtection.points(inventory, :fall) == 64
    assert PlayerDamageProtection.points(inventory, :freeze) == 16
    assert {:ok, 19.999998092651367} = PlayerDamageProtection.damage(inventory, :fall, 100)
    assert {:ok, 0.9999999403953552} = PlayerDamageProtection.damage(inventory, :fall, 5)

    assert PlayerDamageProtection.damage(inventory, :fall, -1) ==
             {:error, :invalid_damage_protection}

    assert PlayerDamageProtection.damage(inventory, :fall, :bad) ==
             {:error, :invalid_damage_protection}
  end

  test "lava and direct fire use armor; ongoing burning bypasses it but retains fire protection" do
    inventory = %Inventory{
      slots: %{
        5 => ItemStack.new("diamond_helmet"),
        6 => ItemStack.new("diamond_chestplate"),
        7 => ItemStack.new("diamond_leggings"),
        8 => ItemStack.new("diamond_boots")
      }
    }

    assert {:ok, 4.0} = PlayerDamageProtection.damage(inventory, :on_fire, 4)

    for source <- [:in_fire, :lava, :hot_floor] do
      assert PlayerDamageProtection.wears_armor?(source)
      assert {:ok, damage} = PlayerDamageProtection.damage(inventory, source, 4)
      assert_in_delta damage, 0.96, 0.000001
    end

    refute PlayerDamageProtection.wears_armor?(:on_fire)

    fire = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:enchantments" => %{
            "minecraft:protection" => 4,
            "minecraft:fire_protection" => 4,
            "minecraft:feather_falling" => 255
          }
        }
    }

    for source <- [:in_fire, :on_fire, :lava, :hot_floor] do
      assert PlayerDamageProtection.points(%Inventory{slots: %{5 => fire}}, source) == 12

      assert PlayerDamageProtection.points(
               %Inventory{slots: %{36 => fire}, carried: fire},
               source
             ) == 0

      assert {:ok, damage} =
               PlayerDamageProtection.damage(%Inventory{slots: %{5 => fire}}, source, 4)

      assert_in_delta damage, 2.08, 0.000001
    end
  end
end
