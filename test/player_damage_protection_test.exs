defmodule Valimc.PlayerDamageProtectionTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerDamageProtection}
  alias Valimc.Protocol.ItemStack

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
end
