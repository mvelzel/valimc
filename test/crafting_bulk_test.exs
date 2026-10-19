defmodule Valimc.CraftingBulkTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, TableMenu}
  alias Valimc.Protocol.ItemStack

  defp grid(size, slots, creative) do
    if size == 2,
      do: %Inventory{slots: slots, infinite_materials: creative},
      else: %Inventory{
        table_inputs: List.to_tuple(Enum.map(1..9, &slots[&1])),
        infinite_materials: creative
      }
  end

  defp plan(inv) do
    if inv.table_inputs,
      do: TableMenu.plan_click(inv, :throw, 0, 1),
      else: Inventory.plan_click(inv, :throw, 0, 1)
  end

  defp drain(inv, original, drops \\ [], batches \\ 0) do
    result = Inventory.crafting_result(inv)

    if result && ItemStack.same_item?(result, original) do
      assert batches < 20
      assert {:ok, next, batch} = plan(inv)
      assert length(batch) in 1..5
      drain(next, original, drops ++ batch, batches + 1)
    else
      {inv, drops, batches}
    end
  end

  test "both menus and permissions consume up to99 crafts through five-record plans" do
    for size <- [2, 3], creative <- [false, true], amount <- [1, 5, 6, 17, 64, 99] do
      log = ItemStack.new("oak_log", amount)

      log =
        if amount > 64, do: %{log | components: %{"minecraft:max_stack_size" => 99}}, else: log

      inv = grid(size, %{1 => log}, creative)
      output = ItemStack.new("oak_planks", 4)
      {final, drops, batches} = drain(inv, output)
      assert length(drops) == amount and Enum.all?(drops, &(&1 == output))
      assert batches == div(amount + 4, 5)
      assert Inventory.crafting_result(final) == nil and final.carried == nil
      assert final.slots == %{}
      assert final.table_inputs in [nil, Tuple.duplicate(nil, 9)]
    end
  end
end
