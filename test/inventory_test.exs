defmodule Valimc.InventoryTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  test "menu has exactly 46 slots; creative writes are bounded and empty slots are sparse" do
    initial = Inventory.new()
    assert Inventory.contents(initial) == List.duplicate(nil, 46)
    stack = ItemStack.new("stone", 16)

    inventory =
      Enum.reduce(1..45, initial, fn slot, inv ->
        assert {:ok, next} = Inventory.creative(inv, slot, stack)
        next
      end)

    assert map_size(inventory.slots) == 45
    assert inventory.state_id == 45
    assert Inventory.get(inventory, 0) == nil

    for slot <- [-999, -1, 0, 46, 32767],
        do: assert(Inventory.creative(inventory, slot, stack) == {:error, :invalid_slot})

    inventory =
      Enum.reduce(1..45, inventory, fn slot, inv ->
        {:ok, next} = Inventory.creative(inv, slot, nil)
        next
      end)

    assert inventory.slots == %{}
    assert initial.slots == %{}
    assert Inventory.advance(%{initial | state_id: 32767}).state_id == 0
  end

  test "selected and offhand stacks are independent and swap as one owner-local operation" do
    main = ItemStack.new("stone", 10)
    off = ItemStack.new("oak_planks", 4)
    {:ok, inv} = Inventory.creative(Inventory.new(), 44, main)
    {:ok, inv} = Inventory.creative(inv, 45, off)
    assert Inventory.held(inv, :main) == nil
    {:ok, inv} = Inventory.select(inv, 8)
    assert inv.state_id == 2
    assert Inventory.held(inv, :main) == main
    assert Inventory.held(inv, :off) == off
    next = Inventory.swap_hands(inv)
    assert next.state_id == 3
    assert Inventory.held(next, :main) == off
    assert Inventory.held(next, :off) == main
    assert Inventory.held(inv, :main) == main

    for slot <- [-1, 9, 32767],
        do: assert(Inventory.select(inv, slot) == {:error, :invalid_selection})
  end
end
