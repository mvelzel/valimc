defmodule Valimc.PlayerCraftingGesturesTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

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
end
