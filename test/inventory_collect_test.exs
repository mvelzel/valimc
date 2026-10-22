defmodule Valimc.InventoryCollectTest do
  use ExUnit.Case, async: true
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.ItemStack

  defp put(inv, slot, stack) do
    {:ok, inv} = Inventory.creative(inv, slot, stack)
    inv
  end

  defp collect(inv, button \\ 0, slot \\ 0) do
    {:ok, inv} = Valimc.TestMenu.click(inv, :pickup_all, slot, button)
    inv
  end

  defp totals(inv) do
    Enum.reduce([inv.carried | Inventory.contents(inv)], %{}, fn
      nil, acc -> acc
      s, acc -> Map.update(acc, {s.item_id, s.components, s.removed}, s.count, &(&1 + s.count))
    end)
  end

  test "partial stacks precede full stacks, with exact capacity and count conservation" do
    inv = %{Inventory.new() | carried: ItemStack.new("stone", 50)}

    inv =
      inv
      |> put(9, ItemStack.new("stone", 64))
      |> put(10, ItemStack.new("stone", 7))
      |> put(11, ItemStack.new("stone", 9))

    next = collect(inv)
    assert next.carried.count == 64
    assert Inventory.get(next, 9).count == 64
    assert Inventory.get(next, 10) == nil and Inventory.get(next, 11).count == 2
    assert totals(next) == totals(inv)
    inv = %{inv | slots: %{9 => ItemStack.new("stone", 64), 10 => ItemStack.new("stone", 3)}}
    next = collect(inv)
    assert next.carried.count == 64 and Inventory.get(next, 9).count == 53
    assert Inventory.get(next, 10) == nil
    assert totals(next) == totals(inv)
  end

  test "patches, effective limits and source slots are respected; result output stays untouched" do
    stone = %{
      ItemStack.new("stone", 5)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    inv = %{Inventory.new() | carried: %{stone | count: 1}}

    inv =
      inv |> put(1, stone) |> put(5, stone) |> put(9, ItemStack.new("stone", 7)) |> put(45, stone)

    inv = %{inv | slots: Map.put(inv.slots, 0, stone)}
    next = collect(inv, 0, 10)
    assert next.carried == %{stone | count: 16}
    assert Inventory.get(next, 0) == stone and Inventory.get(next, 9).count == 7

    assert Inventory.get(next, 1) == nil and Inventory.get(next, 5) == nil and
             Inventory.get(next, 45) == nil

    assert totals(next) == totals(inv)
    inv = %{Inventory.new() | carried: ItemStack.new("egg", 10)}
    inv = put(inv, 9, ItemStack.new("egg", 12))
    next = collect(inv)
    assert next.carried.count == 16 and Inventory.get(next, 9).count == 6
    assert Inventory.encoded_size(next) <= Inventory.encoded_size(inv)
  end

  test "empty/full cursors, occupied triggers and interrupted drags never invent or lose items" do
    inv = put(Inventory.new(), 9, ItemStack.new("stone", 7))
    assert collect(inv).slots == inv.slots and collect(inv).carried == nil
    inv = %{inv | carried: ItemStack.new("stone", 64)}
    assert collect(inv).carried == inv.carried and collect(inv).slots == inv.slots
    inv = %{inv | carried: ItemStack.new("stone", 1)}
    next = collect(inv, 0, 9)
    assert next.slots == inv.slots and next.carried == inv.carried
    {:ok, started} = Valimc.TestMenu.click(inv, :quick_craft, -999, 0)
    next = collect(started)
    assert next.drag == nil and next.slots == inv.slots and next.carried == inv.carried
    assert {:ok, %{slots: slots}} = Valimc.TestMenu.click(inv, :pickup_all, -999, 0)
    assert slots == inv.slots
    assert Valimc.TestMenu.click(inv, :pickup_all, 46, 0) == {:error, :invalid_menu_slot}
    assert Valimc.TestMenu.click(inv, :pickup_all, 0, 2) == {:error, :unsupported_click}
  end

  test "collection conserves all owned component groups across dense inventories" do
    for seed <- 1..100 do
      inv =
        Enum.reduce(1..45, Inventory.new(), fn slot, inv ->
          name = if rem(slot + seed, 3) == 0, do: "egg", else: "stone"
          cap = if name == "egg", do: 16, else: 64

          stack = %{
            ItemStack.new(name, rem(slot * seed, cap) + 1)
            | components: %{"minecraft:enchantment_glint_override" => rem(slot, 2) == 0}
          }

          put(inv, slot, stack)
        end)

      cursor = %{
        ItemStack.new("stone", rem(seed, 63) + 1)
        | components: %{"minecraft:enchantment_glint_override" => true}
      }

      inv = %{inv | carried: cursor}

      for direction <- [0, 1] do
        next = collect(inv, direction)
        assert totals(next) == totals(inv)
        assert next.carried.count <= ItemStack.max_stack_size(next.carried)
        assert Inventory.encoded_size(next) <= Inventory.encoded_size(inv)
      end
    end
  end
end
