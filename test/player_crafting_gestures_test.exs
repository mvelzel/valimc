defmodule Valimc.PlayerCraftingGesturesTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  test "shift repeats into reverse storage, stopping before a changed recipe" do
    inv = %Inventory{slots: %{1 => ItemStack.new("oak_log", 17)}}
    assert {:ok, next, []} = Inventory.plan_click(inv, :quick_move, 0, 0)

    assert next.slots == %{
             44 => ItemStack.new("oak_planks", 64),
             43 => ItemStack.new("oak_planks", 4)
           }

    assert next.carried == nil and Inventory.crafting_result(next) == nil

    inv = %Inventory{
      slots: %{
        1 => ItemStack.new("oak_planks", 2),
        2 => ItemStack.new("oak_planks", 2),
        3 => ItemStack.new("oak_planks"),
        4 => ItemStack.new("oak_planks")
      }
    }

    assert {:ok, next, []} = Inventory.plan_click(inv, :quick_move, 0, 1)
    assert next.slots[44] == ItemStack.new("crafting_table")

    assert next.slots[1] == ItemStack.new("oak_planks") and
             next.slots[2] == ItemStack.new("oak_planks")

    assert Inventory.crafting_result(next) == ItemStack.new("oak_pressure_plate")
  end

  test "partial capacity requires an exact drop plan; a full inventory simply stops" do
    full = Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})
    inv = %Inventory{slots: Map.put(full, 1, ItemStack.new("oak_log", 3))}
    assert {:ok, next, []} = Inventory.plan_click(inv, :quick_move, 0, 0)
    assert next.slots == inv.slots

    for count <- [58, 61, 62, 63] do
      inv = %{inv | slots: Map.put(inv.slots, 44, ItemStack.new("oak_planks", count))}

      assert {:ok, next, [drop]} = Inventory.plan_click(inv, :quick_move, 0, 0)
      assert next.slots[44].count == 64
      assert next.slots[1].count == if(count == 58, do: 1, else: 2)
      assert drop == ItemStack.new("oak_planks", if(count == 58, do: 2, else: count - 60))
      assert Inventory.click(inv, :quick_move, 0, 0) == {:error, :world_drop_required}

      assert inv.slots[1].count == 3 and inv.slots[44].count == count
    end
  end

  test "number/offhand swap crafts exactly once into an empty destination, leaving a carried stack" do
    for creative <- [false, true], button <- [0, 8, 40] do
      target = if button == 40, do: 45, else: 36 + button

      inv = %Inventory{
        infinite_materials: creative,
        slots: %{4 => ItemStack.new("oak_log", 2)},
        carried: ItemStack.new("stone")
      }

      assert {:ok, next, []} = Inventory.plan_click(inv, :swap, 0, button)
      assert next.slots[target] == ItemStack.new("oak_planks", 4)
      assert next.slots[4] == ItemStack.new("oak_log") and next.carried == inv.carried
      assert {:ok, refused, []} = Inventory.plan_click(next, :swap, 0, button)
      assert refused.slots == next.slots and refused.carried == next.carried
    end
  end

  test "clone permission and empty cursor are required; ingredients never change" do
    for creative <- [false, true], cursor <- [nil, ItemStack.new("stone")], button <- [0, 2] do
      inv = %Inventory{
        infinite_materials: creative,
        slots: %{1 => ItemStack.new("oak_log", 2)},
        carried: cursor
      }

      assert {:ok, next, []} = Inventory.plan_click(inv, :clone, 0, button)
      assert next.slots == inv.slots

      assert next.carried ==
               if(creative and cursor == nil, do: ItemStack.new("oak_planks", 64), else: cursor)
    end
  end
end
