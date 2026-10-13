defmodule Valimc.InventoryDragTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  defp click(inv, slot, button) do
    {:ok, next} = Inventory.click(inv, :quick_craft, slot, button)
    next
  end

  defp drag(inv, slots, mode \\ 0) do
    inv = click(inv, -999, mode * 4)
    inv = Enum.reduce(slots, inv, &click(&2, &1, mode * 4 + 1))
    click(inv, -999, mode * 4 + 2)
  end

  test "even and one-per-slot distributions preserve patches, caps and cursor remainders" do
    stone = %{
      ItemStack.new("stone", 17)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    inv = %{Inventory.new() | carried: stone}
    next = drag(inv, [9, 10, 11, 9])
    assert Enum.map(9..11, &Inventory.get(next, &1)) == List.duplicate(%{stone | count: 5}, 3)
    assert next.carried == %{stone | count: 2}
    assert next.drag == nil
    {:ok, inv} = Inventory.creative(inv, 9, %{stone | count: 63})
    next = drag(inv, [9, 10, 11])
    assert Inventory.get(next, 9).count == 64
    assert Inventory.get(next, 10).count == 5
    assert next.carried.count == 6
    next = drag(inv, [9, 10, 11], 1)
    assert Inventory.get(next, 9).count == 64
    assert Inventory.get(next, 10).count == 1
    assert next.carried.count == 14
  end

  test "single target delegates to pickup; duplicates, restrictions and excess targets are bounded" do
    inv = %{Inventory.new() | carried: ItemStack.new("stone", 2)}
    {:ok, inv} = Inventory.creative(inv, 9, ItemStack.new("egg"))
    next = drag(inv, [5, 0, -999, 1000, 9, 10, 10, 11, 12])
    assert Inventory.get(next, 9).item_id == ItemStack.new("egg").item_id
    assert Inventory.get(next, 10).count == 1 and Inventory.get(next, 11).count == 1
    assert Inventory.get(next, 12) == nil and next.carried == nil
    inv = %{Inventory.new() | carried: ItemStack.new("stone", 17)}
    assert drag(inv, [9, 9]).carried == nil
    assert Inventory.get(drag(inv, [9], 1), 9).count == 1
    helmet = %{Inventory.new() | carried: ItemStack.new("iron_helmet")}
    assert Inventory.get(drag(helmet, [5]), 5) == helmet.carried
    bounded = click(inv, -999, 0)
    bounded = Enum.reduce(1..1000, bounded, &click(&2, &1, 1))
    assert MapSet.size(bounded.drag.slots) == 17
    assert Enum.all?(bounded.drag.slots, &(&1 in 9..45))
  end

  test "invalid phase sequences and interrupts leave owned items intact and clear the gesture" do
    inv = %{Inventory.new() | carried: ItemStack.new("stone", 17)}

    for button <- [1, 2, 3, 5, 6, 7] do
      next = click(inv, 9, button)
      assert next.carried == inv.carried and next.slots == inv.slots and next.drag == nil
    end

    started = inv |> click(-999, 0) |> click(9, 1)
    assert started.carried == inv.carried and started.slots == inv.slots
    {:ok, interrupted} = Inventory.click(started, :pickup, 10, 0)
    assert interrupted.carried == inv.carried and interrupted.slots == inv.slots
    assert interrupted.drag == nil
    assert click(started, -999, 0).drag == nil
    {:ok, changed} = Inventory.creative(started, 10, ItemStack.new("egg"))
    assert changed.drag == nil
    assert Inventory.swap_hands(started).drag == nil
    assert click(Inventory.new(), -999, 0).drag == nil
    assert Inventory.click(started, :quick_craft, -999, 12) == {:error, :unsupported_click}
  end

  test "patch multiplication cannot exceed the aggregate correction budget" do
    path = "minecraft:" <> String.duplicate("a", 32600)

    stack = %{
      ItemStack.new("stone", 9)
      | components: %{"minecraft:item_model" => path, "minecraft:tooltip_style" => path}
    }

    inv = %{Inventory.new() | carried: stack}
    started = click(inv, -999, 0)
    started = Enum.reduce(9..17, started, &click(&2, &1, 1))
    assert Inventory.click(started, :quick_craft, -999, 2) == {:error, :inventory_byte_limit}
    assert started.slots == %{} and started.carried == stack
    assert Inventory.cancel_drag(started).drag == nil

    assert Inventory.click(%{inv | carried: ItemStack.new("bundle")}, :quick_craft, -999, 0) ==
             {:error, :unsupported_click}
  end
end
