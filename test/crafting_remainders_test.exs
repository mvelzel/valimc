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

  test "pickup and number conversion journals authorize all exact remainders and reject omissions" do
    for gesture <- [{:pickup, 0}] do
      inv = honey(3, 2, full())
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
