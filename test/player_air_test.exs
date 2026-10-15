defmodule Valimc.PlayerAirTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerAir}
  alias Valimc.Protocol.ItemStack
  alias Valimc.Physics.{BlockCollisions.Frame, PlayerPose}

  test "default submersion has a grace period, bounded repeated damage, and independent surfacing recovery" do
    assert PlayerAir.tick(1, true, false, 0, 0.5) == {0, 0.0}
    assert PlayerAir.tick(-18, true, false, 0, 0.5) == {-19, 0.0}
    assert PlayerAir.tick(-19, true, false, 0, 0.5) == {0, 2.0}
    assert PlayerAir.tick(0, true, false, 0, 0.5) == {-1, 0.0}
    assert PlayerAir.tick(-19, true, true, 0, 0.5) == {-19, 0.0}
    assert PlayerAir.tick(-19, false, false, 0, 0.5) == {-15, 0.0}
    assert PlayerAir.tick(299, false, true, 0, 0.5) == {300, 0.0}
  end

  test "only selected-pose water eyes drain air; both bubble-column states replenish it" do
    frame = %Frame{
      states: %{{0, 64, 0} => 89, {0, 65, 0} => 0, {0, 66, 0} => 0},
      fences: %{},
      entities: %{}
    }

    {:ok, standing} = PlayerPose.geometry(:standing, {0.5, 64.0, 0.5})
    {:ok, swimming} = PlayerPose.geometry(:swimming, {0.5, 64.0, 0.5})
    assert {:ok, false} = PlayerAir.submerged?(frame, standing)
    assert {:ok, true} = PlayerAir.submerged?(frame, swimming)
    full = %{frame | states: Map.put(frame.states, {0, 65, 0}, 89)}
    assert {:ok, true} = PlayerAir.submerged?(full, standing)

    for id <- PlayerAir.bubble_states() do
      assert {:ok, false} =
               PlayerAir.submerged?(
                 %{full | states: Map.put(full.states, {0, 65, 0}, id)},
                 standing
               )
    end

    assert {:error, _} =
             PlayerAir.submerged?(
               %{frame | states: Map.delete(frame.states, {0, 65, 0})},
               standing
             )
  end

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
