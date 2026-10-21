defmodule Valimc.InventoryTransactionsTest do
  use ExUnit.Case, async: true
  alias Valimc.Inventory
  alias Valimc.Protocol.ItemStack

  defp put(inv, slot, stack) do
    {:ok, inv} = Inventory.creative(inv, slot, stack)
    inv
  end

  defp click(inv, action, slot, button \\ 0) do
    {:ok, inv} = Inventory.click(inv, action, slot, button)
    inv
  end

  defp totals(inv) do
    Enum.reduce([inv.carried | Inventory.contents(inv)], %{}, fn
      nil, totals ->
        totals

      stack, totals ->
        Map.update(
          totals,
          {stack.item_id, stack.components, stack.removed},
          stack.count,
          &(&1 + stack.count)
        )
    end)
  end

  test "right-half pickup, one-item placement and capped merging conserve the complete stack" do
    inv = put(Inventory.new(), 9, ItemStack.new("stone", 17))
    inv = click(inv, :pickup, 9, 1)
    assert inv.carried.count == 9 and Inventory.get(inv, 9).count == 8
    inv = click(inv, :pickup, 10, 1)
    assert inv.carried.count == 8 and Inventory.get(inv, 10).count == 1
    inv = click(inv, :pickup, 9)
    assert inv.carried == nil and Inventory.get(inv, 9).count == 16
    inv = put(inv, 11, ItemStack.new("stone", 60))
    inv = inv |> click(:pickup, 9) |> click(:pickup, 11)
    assert Inventory.get(inv, 11).count == 64 and inv.carried.count == 12
    assert totals(inv) == %{{ItemStack.new("stone").item_id, %{}, MapSet.new()} => 77}
  end

  test "different patches swap rather than merge; shift prioritizes existing compatible stacks" do
    plain = ItemStack.new("stone", 8)
    shiny = %{plain | components: %{"minecraft:enchantment_glint_override" => true}}

    inv =
      Inventory.new()
      |> put(9, plain)
      |> put(10, shiny)
      |> click(:pickup, 9)
      |> click(:pickup, 10)

    assert inv.carried == shiny and Inventory.get(inv, 10) == plain
    inv = inv |> click(:pickup, 11) |> put(36, %{shiny | count: 60})
    inv = click(inv, :quick_move, 11)
    assert Inventory.get(inv, 36).count == 64
    assert Inventory.get(inv, 37).count == 4
    assert Inventory.get(inv, 11) == nil
  end

  test "armor auto-equip and restrictions follow pinned item facts; number/offhand swaps are atomic" do
    helmet = ItemStack.new("iron_helmet")
    stone = ItemStack.new("stone", 8)
    inv = Inventory.new() |> put(9, helmet) |> put(36, stone) |> click(:quick_move, 9)
    assert Inventory.get(inv, 5) == helmet and Inventory.get(inv, 9) == nil
    assert Inventory.click(inv, :swap, 5, 0) == {:error, :slot_restricted}
    inv = inv |> click(:swap, 9, 0) |> click(:swap, 9, 40)
    assert Inventory.get(inv, 45) == stone
    assert Inventory.get(inv, 9) == nil and Inventory.get(inv, 36) == nil
    assert Inventory.click(inv, :pickup, -999, 0) == {:error, :unsupported_click}
    assert Inventory.click(inv, :quick_craft, 9, 12) == {:error, :unsupported_click}
  end

  test "aggregate inventory budget keeps corrections bounded and rejected edits preserve old state" do
    path = "minecraft:" <> String.duplicate("a", 32600)

    stack = %{
      ItemStack.new("stone")
      | components: %{"minecraft:item_model" => path, "minecraft:tooltip_style" => path}
    }

    inv = Enum.reduce(9..16, Inventory.new(), fn slot, inv -> put(inv, slot, stack) end)
    assert Inventory.encoded_size(inv) <= 524_288
    assert Inventory.creative(inv, 17, stack) == {:error, :inventory_byte_limit}
    assert Inventory.get(inv, 17) == nil
  end

  test "mixed bounded click sequences preserve item/component totals and slot limits" do
    inv =
      Enum.reduce(9..16, Inventory.new(), fn slot, inv ->
        put(inv, slot, ItemStack.new(if(rem(slot, 2) == 0, do: "stone", else: "egg"), 8))
      end)

    initial = totals(inv)

    {_, _} =
      Enum.reduce(1..300, {inv, :rand.seed_s(:exsss, {17, 37, 59})}, fn _, {inv, random} ->
        {slot, random} = :rand.uniform_s(37, random)
        {kind, random} = :rand.uniform_s(3, random)
        {button, random} = :rand.uniform_s(2, random)
        action = Enum.at([:pickup, :quick_move, :swap], kind - 1)
        next = click(inv, action, slot + 8, button - 1)
        assert totals(next) == initial
        assert map_size(next.slots) <= 45

        for stack <- [next.carried | Inventory.contents(next)],
            stack != nil,
            do: assert(stack.count > 0 and stack.count <= ItemStack.max_stack_size(stack))

        {next, random}
      end)
  end
end
