defmodule Valimc.ContainerClickTest do
  use ExUnit.Case, async: true
  alias Valimc.{ContainerClick, Inventory}
  alias Valimc.Protocol.ItemStack

  defp totals(storage, inventory) do
    (Tuple.to_list(storage) ++ Inventory.contents(inventory) ++ [inventory.carried])
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(%{}, fn stack, totals ->
      Map.update(totals, ItemStack.identity_key(stack), stack.count, &(&1 + stack.count))
    end)
  end

  test "split then single placement conserves stacks and preserves hidden player cells" do
    hidden = ItemStack.new("diamond")
    inventory = %Inventory{slots: %{1 => hidden, 5 => hidden, 45 => hidden}}
    storage = put_elem(Tuple.duplicate(nil, 27), 26, ItemStack.new("stone", 17))
    before = totals(storage, inventory)
    assert {:ok, split, carried} = ContainerClick.plan(3, storage, inventory, :pickup, 26, 1)
    assert elem(split, 26).count == 8 and carried.carried.count == 9
    assert {:ok, after_storage, placed} = ContainerClick.plan(3, split, carried, :pickup, 27, 1)
    assert placed.slots[9] == ItemStack.new("stone") and placed.carried.count == 8
    assert Map.take(placed.slots, [1, 5, 45]) == inventory.slots
    assert totals(after_storage, placed) == before and placed.state_id == 2
  end

  test "chest withdrawal merges before empty slots and visits player storage in reverse" do
    slots = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

    slots =
      slots
      |> Map.put(44, ItemStack.new("stone", 63))
      |> Map.put(35, ItemStack.new("stone", 60))
      |> Map.delete(43)

    inventory = %Inventory{slots: slots}
    storage = put_elem(Tuple.duplicate(nil, 27), 0, ItemStack.new("stone", 17))
    assert {:ok, empty, next} = ContainerClick.plan(3, storage, inventory, :quick_move, 0, 0)
    assert elem(empty, 0) == nil

    assert next.slots[44].count == 64 and next.slots[35].count == 64 and
             next.slots[43].count == 12

    assert totals(empty, next) == totals(storage, inventory)
  end

  test "deposit fills existing matches before first empty container cell and keeps patches separate" do
    storage = Tuple.duplicate(ItemStack.new("bedrock", 64), 27)

    patched = %{
      ItemStack.new("stone", 63)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    storage =
      storage
      |> put_elem(0, ItemStack.new("stone", 63))
      |> put_elem(1, nil)
      |> put_elem(2, patched)
      |> put_elem(26, ItemStack.new("stone", 62))

    inventory = %Inventory{slots: %{36 => ItemStack.new("stone", 7)}}
    assert {:ok, stored, next} = ContainerClick.plan(3, storage, inventory, :quick_move, 54, 1)
    assert next.slots == %{}

    assert elem(stored, 0).count == 64 and elem(stored, 26).count == 64 and
             elem(stored, 1).count == 4

    assert elem(stored, 2) == patched
    assert totals(stored, next) == totals(storage, inventory)
  end

  test "number and offhand swaps keep cursor and hidden cells; aliasing a hotbar cell is a no-op" do
    sword = %{ItemStack.new("diamond_sword") | components: %{"minecraft:damage" => 7}}
    eggs = ItemStack.new("egg", 16)
    cursor = ItemStack.new("stone", 17)
    inventory = %Inventory{slots: %{1 => eggs, 36 => eggs, 45 => eggs}, carried: cursor}
    storage = put_elem(Tuple.duplicate(nil, 54), 2, sword)

    for button <- [0, 40] do
      assert {:ok, swapped, next} = ContainerClick.plan(6, storage, inventory, :swap, 2, button)
      target = if button == 40, do: 45, else: 36
      assert elem(swapped, 2) == eggs and next.slots[target] == sword
      assert next.carried == cursor and next.slots[1] == eggs
      assert totals(swapped, next) == totals(storage, inventory)
    end

    assert {:ok, ^storage, next} = ContainerClick.plan(6, storage, inventory, :swap, 81, 0)
    assert next.slots == inventory.slots and next.carried == cursor
  end

  test "packed storage leaves the source exact; unsupported gestures, overrides and drag refuse whole" do
    storage = Tuple.duplicate(ItemStack.new("bedrock", 64), 27)
    inventory = %Inventory{slots: %{36 => ItemStack.new("diamond", 3)}}
    assert {:ok, ^storage, next} = ContainerClick.plan(3, storage, inventory, :quick_move, 54, 0)
    assert next.slots == inventory.slots

    for {action, wire, button} <- [
          {:throw, 0, 0},
          {:clone, 0, 2},
          {:quick_craft, 0, 0},
          {:pickup_all, 0, 0},
          {:pickup, -999, 0},
          {:pickup, 63, 0}
        ] do
      assert {:error, _} = ContainerClick.plan(3, storage, inventory, action, wire, button)
    end

    assert {:error, :unsupported_container_click} =
             ContainerClick.plan(
               3,
               storage,
               %{inventory | drag: %{mode: 0, slots: MapSet.new()}},
               :pickup,
               0,
               0
             )

    bundle = put_elem(storage, 0, ItemStack.new("bundle"))

    assert {:error, :unsupported_container_click} =
             ContainerClick.plan(3, bundle, inventory, :pickup, 0, 0)

    oversized = put_elem(storage, 0, ItemStack.new("diamond_sword", 2))

    assert {:error, :unsupported_container_click} =
             ContainerClick.plan(3, oversized, inventory, :swap, 0, 0)
  end
end
