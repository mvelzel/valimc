defmodule Valimc.Txn.ReceiptsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{ItemTransfers, Items, PickupTransfers}

  test "drop and pickup plans respect the persisted slot budget and reserved sources can finish at capacity" do
    full = Map.new(1..4096, &{<<&1::128>>, %{sequence: 1, digest: <<1::256>>}})
    new = <<5000::128>>
    assert {:error, :transfer_source_limit} = Valimc.Txn.Receipts.reserve(full, new)
    source = <<1::128>>
    reserved = Map.put(full, source, %{sequence: 0, digest: <<0::256>>})
    record = %{uuid: <<99::128>>, x: 8.5, y: 64.0, z: 8.5, stack: ItemStack.new("stone")}

    assert {:error, :transfer_source_limit} =
             ItemTransfers.plan(Items.new(), reserved, {0, 0}, %{
               source: new,
               sequence: 1,
               records: [record]
             })

    assert {:ok, items, receipts, :applied} =
             ItemTransfers.plan(Items.new(), reserved, {0, 0}, %{
               source: source,
               sequence: 1,
               records: [record]
             })

    assert receipts[source].sequence == 1 and map_size(receipts) == 4096

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

    assert Items.records(plan.items) == [] and map_size(plan.receipts) == 4096
  end
end
