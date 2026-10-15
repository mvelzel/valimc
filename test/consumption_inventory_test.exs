defmodule Valimc.ConsumptionInventoryTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  test "consumption returns a replacement in the emptied hand, merges extras, or reports overflow" do
    soup = %{ItemStack.new("mushroom_stew", 2) | components: %{"minecraft:max_stack_size" => 64}}
    bowl = ItemStack.new("bowl")

    inventory = %Inventory{
      slots: %{36 => soup, 45 => %{bowl | count: 63}},
      drag: %{pending: true}
    }

    assert {:ok, next, []} = Inventory.consume_hand(inventory, :main, bowl)
    assert next.slots[36].count == 1 and next.slots[45].count == 64
    assert next.drag == nil and next.state_id == 1
    assert {:ok, next, []} = Inventory.consume_hand(next, :main, bowl)
    assert next.slots[36] == bowl and next.slots[45].count == 64

    full = %Inventory{
      slots: Map.new(9..45, &{&1, ItemStack.new("stone", 64)}) |> Map.put(45, soup)
    }

    assert {:ok, next, [^bowl]} = Inventory.consume_hand(full, :off, bowl)
    assert next.slots[45].count == 1
    assert {:error, :empty_hand} = Inventory.consume_hand(Inventory.new(), :off, bowl)
  end
end
