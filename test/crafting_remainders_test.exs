defmodule Valimc.CraftingRemaindersTest do
  use ExUnit.Case, async: true
  alias Valimc.{Crafting, Inventory, PlayerCraftingTransfers, PlayerSnapshot}
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

  defp inputs(inv),
    do:
      if(inv.table_inputs,
        do: Tuple.to_list(inv.table_inputs),
        else: Enum.map(1..4, &inv.slots[&1])
      )

  test "consumed containers become fresh bottles in the exact input cells in either permission" do
    for size <- [2, 3], creative <- [false, true] do
      inv = honey(size, 1, full(), creative)
      assert {:ok, next, [output]} = Inventory.plan_click(inv, :throw, 0, 0)
      assert output == ItemStack.new("honey_block")

      assert Enum.reject(inputs(next), &is_nil/1) ==
               List.duplicate(ItemStack.new("glass_bottle"), 4)

      assert Crafting.result(inputs(next)) == :none
      assert Map.take(next.slots, Enum.to_list(9..44)) == full()
    end
  end

  test "stacked inputs emit bottles before thrown output, with creative overflow discarded" do
    for size <- [2, 3], creative <- [false, true] do
      inv = honey(size, 2, full(), creative)
      assert {:ok, next, drops} = Inventory.plan_click(inv, :throw, 0, 0)
      expected = if creative, do: [], else: List.duplicate(ItemStack.new("glass_bottle"), 4)
      assert drops == expected ++ [ItemStack.new("honey_block")]

      assert Enum.reject(inputs(next), &is_nil/1) ==
               List.duplicate(ItemStack.new("honey_bottle"), 4)
    end
  end

  test "matching offhand gets the first remainder before full storage overflows" do
    inv = honey(3, 2, Map.put(full(), 45, ItemStack.new("glass_bottle", 63)))
    assert {:ok, next, drops} = Inventory.plan_click(inv, :pickup, 0, 0)
    assert next.slots[45] == ItemStack.new("glass_bottle", 64)
    assert drops == List.duplicate(ItemStack.new("glass_bottle"), 3)
    assert next.carried == ItemStack.new("honey_block")
  end

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

  test "cake consumes all inputs and returns three plain buckets, retaining stacked input patches" do
    for amount <- [1, 2] do
      milk = %{
        ItemStack.new("milk_bucket", amount)
        | components: %{
            "minecraft:max_stack_size" => 99,
            "minecraft:enchantment_glint_override" => true
          }
      }

      cells =
        [
          milk,
          milk,
          milk,
          ItemStack.new("sugar", amount),
          ItemStack.new("egg", amount),
          ItemStack.new("sugar", amount)
        ] ++ List.duplicate(ItemStack.new("wheat", amount), 3)

      inv = %Inventory{table_inputs: List.to_tuple(cells)}
      assert {:ok, next, []} = Inventory.plan_click(inv, :pickup, 0, 0)
      assert next.carried == ItemStack.new("cake")

      if amount == 1 do
        assert Enum.take(inputs(next), 3) == List.duplicate(ItemStack.new("bucket"), 3)
        assert Enum.drop(inputs(next), 3) == List.duplicate(nil, 6)
      else
        assert Enum.take(inputs(next), 3) == List.duplicate(%{milk | count: 1}, 3)
        assert next.slots[36] == ItemStack.new("bucket", 3)
      end
    end
  end

  test "two effects per craft stop a batch at four records and continue without losing its boundary" do
    inv = %Inventory{slots: Map.put(full(), 1, ItemStack.new("honey_bottle", 6))}
    assert {:ok, next, first} = Inventory.plan_click(inv, :throw, 0, 1)
    assert length(first) == 4 and next.slots[1] == ItemStack.new("honey_bottle", 4)

    {last, drops} =
      Enum.reduce(1..2, {next, first}, fn _, {inv, drops} ->
        assert {:ok, next, batch} = Inventory.plan_click(inv, :throw, 0, 1)
        assert length(batch) <= 5
        {next, drops ++ batch}
      end)

    assert last.slots[1] == ItemStack.new("glass_bottle")
    assert Enum.count(drops, &(&1 == ItemStack.new("sugar", 3))) == 6
    assert Enum.count(drops, &(&1 == ItemStack.new("glass_bottle"))) == 5
    assert Inventory.crafting_result(last) == nil
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
