defmodule Valimc.InventoryCreativeTransactionsTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  defp put(inv, slot, stack) do
    {:ok, inv} = Inventory.creative(inv, slot, stack)
    inv
  end

  defp click(inv, action, slot, button) do
    {:ok, inv} = Inventory.click(inv, action, slot, button)
    inv
  end

  defp fill(inv, slots) do
    inv = click(inv, :quick_craft, -999, 8)
    inv = Enum.reduce(slots, inv, &click(&2, :quick_craft, &1, 9))
    click(inv, :quick_craft, -999, 10)
  end

  test "clone requires owner permission and an empty cursor; source and exact patches survive" do
    stack = %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"probe" => {:string, "clone"}}}
        }
    }

    inv = put(Inventory.new(), 9, stack)
    assert not inv.infinite_materials
    next = click(inv, :clone, 9, 2)
    assert next.carried == nil and next.slots == inv.slots
    inv = %{inv | infinite_materials: true}
    next = click(inv, :clone, 9, 2)
    assert next.carried == %{stack | count: 64}
    assert next.slots == inv.slots
    assert click(next, :clone, 9, 2).carried == next.carried
    assert click(inv, :clone, 10, 2).carried == nil
    eggs = put(Inventory.new(true), 9, ItemStack.new("egg", 3))
    assert click(eggs, :clone, 9, 2).carried.count == 16
    assert Inventory.click(inv, :clone, -999, 2) == {:error, :unsupported_click}
    assert Inventory.click(inv, :clone, 46, 2) == {:error, :unsupported_click}
  end

  test "creative fill bypasses cursor count, deduplicates targets and preserves compatible components" do
    stack = %{
      ItemStack.new("stone")
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    inv = %{Inventory.new(true) | carried: stack}
    inv = inv |> put(9, %{stack | count: 63}) |> put(12, ItemStack.new("stone", 7))
    next = fill(inv, [5, 0, 9, 10, 10, 12, 46])
    assert Inventory.get(next, 9) == %{stack | count: 64}
    assert Inventory.get(next, 10) == %{stack | count: 64}
    assert Inventory.get(next, 12) == Inventory.get(inv, 12)
    assert next.carried == nil and next.drag == nil
    started = click(inv, :quick_craft, -999, 8)
    bounded = Enum.reduce(1..1000, started, &click(&2, :quick_craft, &1, 9))
    assert MapSet.size(bounded.drag.slots) == 40
  end

  test "single/no targets and already full targets retain the cursor; item and equipment caps hold" do
    inv = %{Inventory.new(true) | carried: ItemStack.new("stone")}
    assert fill(inv, [9]).carried == inv.carried and fill(inv, [9]).slots == inv.slots
    assert fill(inv, []).carried == inv.carried and fill(inv, []).drag == nil
    inv = inv |> put(9, ItemStack.new("stone", 64)) |> put(10, ItemStack.new("stone", 64))
    assert fill(inv, [9, 10]).carried == inv.carried
    eggs = %{Inventory.new(true) | carried: ItemStack.new("egg")}
    filled = fill(eggs, [9, 10])
    assert Inventory.get(filled, 9).count == 16 and Inventory.get(filled, 10).count == 16
    helmet = %{Inventory.new(true) | carried: ItemStack.new("iron_helmet")}
    filled = fill(helmet, [5, 9])
    assert Inventory.get(filled, 5).count == 1 and Inventory.get(filled, 9).count == 1
    assert filled.carried == nil
    bundle = %{Inventory.new(true) | carried: ItemStack.new("bundle")}
    filled = fill(bundle, [9, 10])
    assert Inventory.get(filled, 9).count == 1 and Inventory.get(filled, 10).count == 1
  end

  test "fill permission is sampled at start; cancellation and ordinary interrupts prevent completion" do
    inv = %{Inventory.new() | carried: ItemStack.new("stone")}
    next = fill(inv, [9, 10])
    assert next.slots == %{} and next.carried == inv.carried and next.drag == nil
    started = click(%{inv | infinite_materials: true}, :quick_craft, -999, 8)
    started = click(started, :quick_craft, 9, 9) |> click(:quick_craft, 10, 9)
    revoked = %{started | infinite_materials: false}
    next = click(revoked, :quick_craft, -999, 10)
    assert Inventory.get(next, 9).count == 64 and Inventory.get(next, 10).count == 64
    assert next.carried == nil and next.drag == nil
    canceled = Inventory.cancel_drag(revoked)
    next = click(canceled, :quick_craft, -999, 10)
    assert next.slots == %{} and next.carried == inv.carried and next.drag == nil
    next = click(started, :pickup, 11, 0)
    assert next.slots == %{} and next.carried == inv.carried and next.drag == nil
  end

  test "component duplication is atomic at the aggregate byte limit" do
    path = "minecraft:" <> String.duplicate("a", 32600)

    stack = %{
      ItemStack.new("stone")
      | components: %{"minecraft:item_model" => path, "minecraft:tooltip_style" => path}
    }

    inv = Enum.reduce(9..16, Inventory.new(true), &put(&2, &1, stack))
    assert Inventory.click(inv, :clone, 9, 2) == {:error, :inventory_byte_limit}
    assert inv.carried == nil and Inventory.get(inv, 9) == stack
    started = click(%{Inventory.new(true) | carried: stack}, :quick_craft, -999, 8)
    started = Enum.reduce(9..17, started, &click(&2, :quick_craft, &1, 9))
    assert Inventory.click(started, :quick_craft, -999, 10) == {:error, :inventory_byte_limit}
    assert started.slots == %{} and started.carried == stack
  end
end
