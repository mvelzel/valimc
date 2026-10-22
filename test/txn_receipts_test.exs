defmodule Valimc.Txn.ReceiptsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{ItemTransfers, Entities, PickupTransfers}

  test "a new source always gets a slot: receipt tables have no source cap (VMC-077h)" do
    full = Map.new(1..4096, &{<<&1::128>>, %{sequence: 1, digest: <<1::256>>}})
    source = <<5000::128>>
    assert {:ok, reserved, :reserved} = Valimc.Txn.Receipts.reserve(full, source)
    record = %{uuid: <<99::128>>, x: 8.5, y: 64.0, z: 8.5, stack: ItemStack.new("stone")}

    assert {:ok, items, receipts, :applied} =
             ItemTransfers.plan(Entities.new(), reserved, {0, 0}, %{
               source: source,
               sequence: 1,
               records: [record]
             })

    assert receipts[source].sequence == 1 and map_size(receipts) == 4097

    request = %{
      source: source,
      sequence: 2,
      permit: <<4::128>>,
      item_uuid: record.uuid,
      generation: 0,
      before: record.stack,
      remainder: nil
    }

    assert {:ok, %{result: :applied} = plan} =
             PickupTransfers.plan(items, receipts, {0, 0}, request, true)

    assert Entities.records(plan.items) == [] and map_size(plan.receipts) == 4097
  end
end
