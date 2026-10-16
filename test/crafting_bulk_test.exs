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

  test "bulk stops before a different recipe result, including across a five-craft boundary" do
    for size <- [2, 3], creative <- [false, true], amount <- [1, 5, 6] do
      bottom = if size == 2, do: [3, 4], else: [4, 5]
      inputs = Map.new([1, 2], &{&1, ItemStack.new("oak_planks", amount)})

      inputs =
        Enum.reduce(bottom, inputs, &Map.put(&2, &1, ItemStack.new("oak_planks", amount + 1)))

      inv = grid(size, inputs, creative)
      output = ItemStack.new("crafting_table")
      {final, drops, _} = drain(inv, output)
      assert drops == List.duplicate(output, amount)
      assert Inventory.crafting_result(final) == ItemStack.new("oak_pressure_plate")
      assert {:ok, next, [plate]} = plan(final)
      assert plate == ItemStack.new("oak_pressure_plate")
      assert Inventory.crafting_result(next) == nil
    end
  end

  test "cursor ownership refuses bulk without touching ingredients" do
    for size <- [2, 3], creative <- [false, true] do
      inv = %{
        grid(size, %{1 => ItemStack.new("oak_log", 17)}, creative)
        | carried: ItemStack.new("stone")
      }

      assert {:ok, next, []} = plan(inv)
      assert next.slots == inv.slots and next.table_inputs == inv.table_inputs
      assert next.carried == inv.carried
    end
  end

  test "remaining patched inputs retain their identity and unpatched outputs have native counts" do
    patched = %{
      ItemStack.new("oak_log", 6)
      | components: %{"minecraft:enchantment_glint_override" => true}
    }

    for size <- [2, 3] do
      inv = grid(size, %{1 => patched}, false)
      assert {:ok, next, drops} = plan(inv)
      assert drops == List.duplicate(ItemStack.new("oak_planks", 4), 5)
      remaining = if size == 2, do: next.slots[1], else: elem(next.table_inputs, 0)
      assert remaining == %{patched | count: 1}
    end
  end
end
