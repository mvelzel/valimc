defmodule Valimc.TableMenuTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, TableMenu}
  alias Valimc.Protocol.ItemStack

  defp table(cells, slots) do
    %Inventory{table_inputs: Enum.map(1..9, &cells[&1]) |> List.to_tuple(), slots: slots}
  end

  defp pickaxe do
    table(
      %{
        1 => ItemStack.new("oak_planks", 2),
        2 => ItemStack.new("spruce_planks", 2),
        3 => ItemStack.new("birch_planks", 2),
        5 => ItemStack.new("stick", 2),
        8 => ItemStack.new("stick", 2)
      },
      %{
        1 => ItemStack.new("diamond", 7),
        5 => ItemStack.new("iron_helmet"),
        45 => ItemStack.new("shield")
      }
    )
  end

  test "logical slots map to table inputs and storage while physical hands/equipment stay stable" do
    inv = pickaxe()

    assert TableMenu.address(1) == {:ok, {:table, 0}} and
             TableMenu.address(9) == {:ok, {:table, 8}}

    assert TableMenu.address(10) == {:ok, 9} and TableMenu.address(45) == {:ok, 44}

    for slot <- [-2, 46, 99],
        do: assert(TableMenu.plan_click(inv, :pickup, slot, 0) == {:error, :invalid_table_slot})

    assert TableMenu.plan_click(Inventory.new(), :pickup, 1, 0) == {:error, :table_not_open}
    assert length(TableMenu.contents(inv)) == 46
    assert Enum.at(TableMenu.contents(inv), 5) == ItemStack.new("stick", 2)

    assert Inventory.get(inv, 5) == ItemStack.new("iron_helmet") and
             Inventory.held(inv, :off) == ItemStack.new("shield")

    assert hd(TableMenu.contents(inv)) == ItemStack.new("wooden_pickaxe")
    {:ok, next, []} = TableMenu.plan_click(inv, :pickup, 0, 1)
    assert next.carried == ItemStack.new("wooden_pickaxe")
    assert Enum.all?(Inventory.table_contents(next) |> Enum.reject(&is_nil/1), &(&1.count == 1))
    assert next.slots == inv.slots and Inventory.get(next, 0) == nil
    assert {:ok, unchanged, []} = TableMenu.plan_click(next, :pickup, 0, 0)
    assert unchanged.table_inputs == next.table_inputs and unchanged.carried == next.carried
  end
end
