defmodule Valimc.InventoryDropPlanTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  defp stone do
    %{
      ItemStack.new("stone", 7)
      | components: %{
          "minecraft:enchantment_glint_override" => true,
          "minecraft:custom_data" => {:compound, %{"drop" => {:string, "exact"}}}
        },
        removed: MapSet.new(["minecraft:rarity"])
    }
  end

  test "outside primary/secondary plans consume exact cursor counts for pickup and quick move" do
    cursor = stone()

    original = %Inventory{
      carried: cursor,
      selected: 3,
      slots: %{39 => ItemStack.new("egg", 2)},
      state_id: 32767
    }

    for action <- [:pickup, :quick_move], button <- [0, 1] do
      assert {:ok, next, [drop]} = Inventory.plan_click(original, action, -999, button)
      count = if button == 0, do: 7, else: 1
      assert drop == %{cursor | count: count}
      assert next.carried == if(button == 0, do: nil, else: %{cursor | count: 6})
      assert next.slots == original.slots and next.selected == 3 and next.state_id == 0
      assert original.carried == cursor
    end

    for button <- [0, 1], action <- [:pickup, :quick_move] do
      assert {:ok, empty, []} = Inventory.plan_click(%Inventory{}, action, -999, button)
      assert empty.carried == nil
    end

    assert {:error, :unsupported_click} = Inventory.plan_click(original, :pickup, -999, 2)
  end

  test "throw removes one or all from grid, equipment, storage, hotbar and offhand" do
    stack = stone()

    for slot <- [1, 5, 9, 36, 45], button <- [0, 1, 2, -1, -128, 127] do
      original = %Inventory{slots: %{slot => stack}, selected: 8}
      assert {:ok, next, [drop]} = Inventory.plan_click(original, :throw, slot, button)
      count = if button == 0, do: 1, else: 7
      assert drop == %{stack | count: count}
      assert next.slots[slot] == if(button == 0, do: %{stack | count: 6}, else: nil)
      assert next.selected == 8 and next.carried == nil
    end
  end

  test "throw is a no-op with a cursor or empty/negative slots; invalid slots never consume" do
    stack = stone()
    original = %Inventory{slots: %{9 => stack}, carried: ItemStack.new("egg", 1)}

    for button <- [0, 1, 2] do
      assert {:ok, next, []} = Inventory.plan_click(original, :throw, 9, button)
      assert next.slots == original.slots and next.carried == original.carried
    end

    for slot <- [0, 8, -1, -999] do
      assert {:ok, _, []} = Inventory.plan_click(%{original | carried: nil}, :throw, slot, 1)
    end

    for slot <- [-1000, -2, 46, 32767], button <- [0, 1] do
      assert {:error, :unsupported_click} = Inventory.plan_click(original, :throw, slot, button)
    end
  end

  test "an interrupting effectful click cancels quick craft before any drop can be planned" do
    stack = stone()
    original = %Inventory{carried: stack, drag: %{mode: 0, slots: MapSet.new([9])}}
    assert {:ok, interrupted, []} = Inventory.plan_click(original, :pickup, -999, 0)
    assert interrupted.carried == stack and interrupted.drag == nil
    assert {:ok, completed, [^stack]} = Inventory.plan_click(interrupted, :pickup, -999, 0)
    assert completed.carried == nil
    original = %{original | carried: nil, slots: %{9 => stack}}
    assert {:ok, interrupted, []} = Inventory.plan_click(original, :throw, 9, 1)
    assert interrupted.slots[9] == stack and interrupted.drag == nil
    assert {:ok, _, [^stack]} = Inventory.plan_click(interrupted, :throw, 9, 1)
  end
end
