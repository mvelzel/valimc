defmodule Valimc.ItemReceiptsTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{
    ItemLedger,
    ItemReceipts,
    ItemRecords,
    ItemTransfers,
    Items,
    PickupTransfers
  }

  test "persisted reservation preserves every existing high-water mark without approving a transfer" do
    source = <<8::128>>
    prior = %{<<9::128>> => %{sequence: 7, digest: <<11::256>>}}
    assert {:ok, reserved, :reserved} = ItemReceipts.reserve(prior, source)
    assert reserved[<<9::128>>] == prior[<<9::128>>]
    assert reserved[source] == %{sequence: 0, digest: <<0::256>>}
    assert {:ok, ^reserved, :existing} = ItemReceipts.reserve(reserved, source)
    assert {:ok, bytes} = ItemLedger.encode({0, 0}, [], reserved, %ItemLedger{})
    assert {:ok, %{records: [], receipts: ^reserved}} = ItemLedger.decode(bytes, {0, 0})

    request = %{
      source: source,
      sequence: 1,
      permit: <<4::128>>,
      item_uuid: <<5::128>>,
      generation: 0,
      before: ItemStack.new("stone"),
      remainder: nil
    }

    assert {:error, :stale_transfer} =
             PickupTransfers.receipt_result({0, 0}, request, reserved[source])

    assert {:ok, %{result: :rejected} = plan} =
             PickupTransfers.plan(Items.new(), reserved, {0, 0}, request, false)

    assert {:ok, :rejected} =
             PickupTransfers.receipt_result({0, 0}, request, plan.receipts[source])

    assert {:ok, unchanged, :existing} = ItemReceipts.reserve(plan.receipts, source)
    assert unchanged == plan.receipts
  end

  test "drop and pickup plans respect the persisted slot budget and reserved sources can finish at capacity" do
    full = Map.new(1..4096, &{<<&1::128>>, %{sequence: 1, digest: <<1::256>>}})
    new = <<5000::128>>
    assert {:error, :transfer_source_limit} = ItemReceipts.reserve(full, new)
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

  test "zero sequences with another digest and malformed reservations remain invalid" do
    refute ItemReceipts.valid?(%{sequence: 0, digest: <<1::256>>})

    assert {:error, :invalid_item_records} =
             ItemRecords.encode({0, 0}, [], %{<<1::128>> => %{sequence: 0, digest: <<1::256>>}})

    assert {:error, :invalid_receipt_reservation} = ItemReceipts.reserve(%{}, <<1>>)

    assert {:error, :invalid_receipt_reservation} =
             ItemReceipts.reserve(
               %{<<1::128>> => %{sequence: -1, digest: <<0::256>>}},
               <<1::128>>
             )
  end
end
