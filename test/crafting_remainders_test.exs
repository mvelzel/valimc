defmodule Valimc.CraftingRemaindersTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, PlayerCraftingTransfers, PlayerSnapshot}
  alias Valimc.Protocol.ItemStack

  defp honey(size, amount, slots, creative \\ false) do
    cells = if size == 2, do: [1, 2, 3, 4], else: [1, 2, 4, 5]
    inputs = Map.new(cells, &{&1, ItemStack.new("honey_bottle", amount)})

    if size == 2,
      do: %Inventory{slots: Map.merge(slots, inputs), infinite_materials: creative},
      else: %Inventory{
        slots: slots,
        table_inputs: List.to_tuple(Enum.map(1..9, &inputs[&1])),
        infinite_materials: creative
      }
  end

  defp full, do: Map.new(9..44, &{&1, ItemStack.new("bedrock", 64)})

  test "a three-sugar result must fit before any input or remainder is spent" do
    inv = %Inventory{slots: Map.put(full(), 1, ItemStack.new("honey_bottle", 2))}

    for cursor <- [ItemStack.new("stone"), ItemStack.new("sugar", 62), ItemStack.new("sugar", 64)],
        button <- [0, 1] do
      before = %{inv | carried: cursor}
      assert {:ok, next, []} = Inventory.plan_click(before, :pickup, 0, button)
      assert next.slots == before.slots and next.carried == cursor
      assert {:ok, unchanged, []} = Inventory.plan_click(before, :throw, 0, 1)
      assert unchanged.slots == before.slots and unchanged.carried == cursor
    end

    assert {:ok, next, [bottle]} =
             Inventory.plan_click(%{inv | carried: ItemStack.new("sugar", 61)}, :pickup, 0, 0)

    assert bottle == ItemStack.new("glass_bottle") and next.carried == ItemStack.new("sugar", 64)
    assert next.slots[1] == ItemStack.new("honey_bottle")
  end

  test "number result occupies its target before returning containers, never overwriting them" do
    inv = honey(2, 2, Map.delete(full(), 36))
    assert {:ok, next, drops} = Inventory.plan_click(inv, :swap, 0, 0)
    assert next.slots[36] == ItemStack.new("honey_block")
    assert drops == List.duplicate(ItemStack.new("glass_bottle"), 4)
    assert next.carried == nil
  end

  test "pickup and number conversion journals authorize all exact remainders and reject omissions" do
    for gesture <- [{:pickup, 0}, {:swap, 0}] do
      inv = honey(3, 2, if(elem(gesture, 0) == :swap, do: Map.delete(full(), 36), else: full()))
      {action, button} = gesture
      assert {:ok, next, drops} = Inventory.plan_click(inv, action, 0, button)
      before = %{pose: %{x: 7.5, y: 64.0, z: 3.5, yaw: 0.0, pitch: 0.0}, inventory: inv}
      after_snapshot = %{before | inventory: next}

      records =
        Enum.with_index(drops, 1)
        |> Enum.map(fn {stack, n} ->
          %{uuid: <<n::128>>, x: 7.5, y: 65.31999999284744, z: 3.5, stack: stack}
        end)

      assert {:ok, pending} =
               PlayerCraftingTransfers.prepare(
                 <<31::128>>,
                 0,
                 before,
                 after_snapshot,
                 {0, 0},
                 records,
                 gesture
               )

      assert pending.outbox.records == records and pending.transfer_sequence == 1
      assert {:ok, bytes} = PlayerSnapshot.encode(<<31::128>>, pending)
      assert {:ok, decoded} = PlayerSnapshot.decode(bytes, <<31::128>>)

      assert decoded.inventory.table_inputs == next.table_inputs and
               decoded.outbox == pending.outbox

      assert {:error, :invalid_crafting_transfer} =
               PlayerCraftingTransfers.prepare(
                 <<31::128>>,
                 0,
                 before,
                 after_snapshot,
                 {0, 0},
                 tl(records),
                 gesture
               )

      assert {:error, :invalid_crafting_transfer} =
               PlayerCraftingTransfers.prepare(
                 <<31::128>>,
                 0,
                 before,
                 before,
                 {0, 0},
                 records,
                 gesture
               )
    end
  end
end
