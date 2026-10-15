defmodule Valimc.PlayerAirTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerAir}
  alias Valimc.Protocol.ItemStack

  test "zero air has a twenty-tick grace; surfacing restores four and caps at native maximum" do
    assert PlayerAir.decrease(1, 0, 0.99) == 0
    assert PlayerAir.decrease(0, 0, 0.99) == -1
    refute PlayerAir.drowning?(-19)
    assert PlayerAir.drowning?(PlayerAir.decrease(-19, 0, 0.99))
    assert PlayerAir.increase(-19) == -15
    assert PlayerAir.increase(299) == PlayerAir.maximum()
    assert PlayerAir.valid?(-20) and PlayerAir.valid?(300)
    refute PlayerAir.valid?(-21)
    refute PlayerAir.valid?(301)
  end

  test "oxygen preserves air on the native threshold and uses only direct head enchantments" do
    stack = %{
      ItemStack.new("iron_helmet")
      | components: %{
          "minecraft:enchantments" => %{"minecraft:respiration" => 3}
        }
    }

    inventory = %Inventory{slots: %{5 => stack}}
    assert PlayerAir.oxygen_bonus(inventory) == 3
    assert PlayerAir.decrease(10, 3, 0.24999999999999997) == 9
    assert PlayerAir.decrease(10, 3, 0.25) == 10

    for slot <- [6, 7, 8, 36, 45],
        do: assert(PlayerAir.oxygen_bonus(%Inventory{slots: %{slot => stack}}) == 0)

    stack = %{
      stack
      | components: %{"minecraft:stored_enchantments" => %{"minecraft:respiration" => 3}}
    }

    assert PlayerAir.oxygen_bonus(%Inventory{slots: %{5 => stack}}) == 0
  end
end
