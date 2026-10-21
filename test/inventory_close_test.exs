defmodule Valimc.InventoryCloseTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  defp put(inv, slot, stack) do
    {:ok, inv} = Inventory.creative(inv, slot, stack)
    inv
  end

  defp shiny(count) do
    %{
      ItemStack.new("stone", count)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"close" => {:string, "preserved"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }
  end

  test "disconnect drops whole cursor/grid stacks in order despite free storage and merge space" do
    for permission <- [false, true] do
      sword = %{ItemStack.new("iron_sword") | components: %{"minecraft:damage" => 17}}

      inv = %Inventory{
        infinite_materials: permission,
        selected: 2,
        carried: shiny(10),
        drag: %{mode: 0, slots: MapSet.new([9])},
        slots: %{
          0 => ItemStack.new("gold_ingot"),
          1 => ItemStack.new("egg", 3),
          2 => ItemStack.new("dirt", 4),
          3 => sword,
          4 => shiny(1),
          38 => shiny(63),
          45 => ItemStack.new("egg", 3)
        }
      }

      {:ok, returned, []} = Inventory.close(inv)
      assert returned.slots[38] == shiny(64) and returned.slots[45].count == 6
      {:ok, next, drops} = Inventory.disconnect(inv)
      assert drops == [inv.carried | Enum.map(1..4, &inv.slots[&1])]
      assert next.slots == Map.take(inv.slots, [38, 45])
      assert next.selected == 2 and next.carried == nil and next.drag == nil
      assert {:ok, _, []} = Inventory.disconnect(next)
    end
  end

  test "return merges selected, offhand, then hotbar/main before using empty storage" do
    inv = %{
      Inventory.new(true)
      | selected: 2,
        carried: shiny(17),
        drag: %{mode: 0, slots: MapSet.new()}
    }

    inv = Enum.reduce([38, 45, 36, 9], inv, &put(&2, &1, shiny(60)))
    inv = %{inv | drag: %{mode: 0, slots: MapSet.new([10])}}
    {:ok, next, []} = Inventory.close(inv)
    for slot <- [38, 45, 36, 9], do: assert(Inventory.get(next, slot) == shiny(64))
    assert Inventory.get(next, 37) == shiny(1)
    assert next.carried == nil and next.drag == nil and next.selected == 2
    assert next.state_id == inv.state_id + 1
    {:ok, again, []} = Inventory.close(next)
    assert again.slots == next.slots and again.carried == nil
  end

  test "empty storage uses vanilla indices and never auto-equips; incompatible patches stay separate" do
    inv = %{Inventory.new() | selected: 7, carried: shiny(9)}
    inv = inv |> put(36, ItemStack.new("stone", 7)) |> put(45, ItemStack.new("stone", 8))
    {:ok, next, []} = Inventory.close(inv)
    assert Inventory.get(next, 37) == shiny(9)
    assert Inventory.get(next, 36) == Inventory.get(inv, 36)
    assert Inventory.get(next, 45) == Inventory.get(inv, 45)
    assert Inventory.get(next, 43) == nil
    inv = Enum.reduce(36..44, Inventory.new(), &put(&2, &1, ItemStack.new("stone", 64)))
    helmet = ItemStack.new("iron_helmet")
    {:ok, next, []} = Inventory.close(%{inv | carried: helmet})
    assert Inventory.get(next, 9) == helmet and Inventory.get(next, 5) == nil
    assert Inventory.get(next, 45) == nil
  end

  test "cursor returns before grid inputs and virtual result is discarded; single stacks preserve damage" do
    sword = %{ItemStack.new("iron_sword") | components: %{"minecraft:damage" => 17}}
    inv = %{Inventory.new() | carried: ItemStack.new("dirt", 2)}
    inv = inv |> put(1, shiny(3)) |> put(2, ItemStack.new("egg", 16))
    inv = inv |> put(3, ItemStack.new("bundle")) |> put(4, sword)
    inv = %{inv | slots: Map.put(inv.slots, 0, ItemStack.new("gold_ingot"))}
    {:ok, next, []} = Inventory.close(inv)
    assert Inventory.get(next, 36) == inv.carried

    for {source, target} <- [{1, 37}, {2, 38}, {3, 39}, {4, 40}] do
      assert Inventory.get(next, target) == Inventory.get(inv, source)
    end

    assert Enum.all?(0..4, &(Inventory.get(next, &1) == nil))
    assert next.carried == nil
    {:ok, next, []} = Inventory.close(%{next | carried: sword})
    assert Inventory.get(next, 40) == sword and Inventory.get(next, 41) == sword
  end

  test "overflow effects conserve counts and order with full/partial storage in either permission mode" do
    for permission <- [false, true] do
      full =
        Enum.reduce(
          Enum.to_list(36..44) ++ Enum.to_list(9..35),
          Inventory.new(permission),
          &put(&2, &1, shiny(64))
        )

      inv = %{full | carried: shiny(10), drag: %{mode: 0, slots: MapSet.new()}}
      inv = inv |> put(36, shiny(63)) |> put(1, ItemStack.new("egg", 3))
      inv = %{inv | drag: %{mode: 0, slots: MapSet.new([9])}}
      {:ok, next, [stone, eggs]} = Inventory.close(inv)
      assert stone == shiny(9) and eggs == ItemStack.new("egg", 3)
      assert Inventory.get(next, 36) == shiny(64)
      assert next.carried == nil and next.drag == nil
      assert Inventory.get(next, 1) == nil and Inventory.get(next, 45) == nil
      assert inv.carried == shiny(10) and Inventory.get(inv, 36) == shiny(63)
    end
  end
end
