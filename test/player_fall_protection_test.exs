defmodule Valimc.PlayerFallProtectionTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerFallProtection}
  alias Valimc.Protocol.ItemStack

  test "native worn slot rules include patched armor and exclude carried/stored/hand enchantments" do
    stack = %{
      ItemStack.new("iron_boots")
      | components: %{"minecraft:enchantments" => %{"minecraft:feather_falling" => 4}}
    }

    for slot <- 5..8 do
      assert PlayerFallProtection.points(%Inventory{slots: %{slot => stack}}) == 12
    end

    for slot <- [1, 9, 36, 45] do
      assert PlayerFallProtection.points(%Inventory{slots: %{slot => stack}, carried: stack}) == 0
    end

    stored = %{
      stack
      | components: %{"minecraft:stored_enchantments" => %{"minecraft:feather_falling" => 255}}
    }

    assert {:ok, 5.0} = PlayerFallProtection.damage(%Inventory{slots: %{8 => stored}}, 5)
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
    assert PlayerFallProtection.points(inventory) == 64
    assert {:ok, 19.999998092651367} = PlayerFallProtection.damage(inventory, 100)
    assert {:ok, 0.9999999403953552} = PlayerFallProtection.damage(inventory, 5)
    assert PlayerFallProtection.damage(inventory, -1) == {:error, :invalid_fall_protection}
    assert PlayerFallProtection.damage(inventory, :bad) == {:error, :invalid_fall_protection}
  end
end
