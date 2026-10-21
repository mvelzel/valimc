defmodule Valimc.PickupTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{ItemLedger, ItemTransfers, Items, PickupTransfers}

  defp scene(motion \\ %ItemMotionState{}) do
    record = %{
      uuid: <<71::128>>,
      x: 8.5,
      y: 64.0,
      z: 8.5,
      stack: ItemStack.new("stone", 7),
      motion: motion
    }

    {:ok, items} = Items.restore({0, 0}, [record], %ItemLedger{generations: %{record.uuid => 3}})

    request = %{
      source: <<1::128>>,
      sequence: 4,
      permit: <<13::128>>,
      item_uuid: record.uuid,
      generation: 3,
      before: record.stack,
      remainder: nil
    }

    {items, request, record}
  end

  defp recovered(items, receipts) do
    {:ok, bytes} = ItemLedger.encode({0, 0}, Items.records(items), receipts, items.ledger)
    {:ok, disk} = ItemLedger.decode(bytes, {0, 0})
    {:ok, items} = Items.restore({0, 0}, disk.records, disk.ledger)
    {items, disk.receipts}
  end

  test "withdrawal and typed receipt replay never resurrect an item or lose its birth history" do
    {items, request, record} = scene()
    birth = %{source: request.source, sequence: 3, records: [record]}
    {:ok, birth_digest} = ItemTransfers.digest({0, 0}, birth)

    receipts = %{
      request.source => %{sequence: 3, digest: birth_digest},
      <<9::128>> => %{sequence: 8, digest: <<99::256>>}
    }

    assert {:ok, %{result: :applied} = plan} =
             PickupTransfers.plan(items, receipts, {0, 0}, request, true)

    assert Items.records(plan.items) == [] and plan.items.ledger.generations == %{}
    assert plan.receipts[<<9::128>>] == receipts[<<9::128>>]

    assert {:ok, :applied} =
             PickupTransfers.receipt_result({0, 0}, request, plan.receipts[request.source])

    {restored, receipts} = recovered(plan.items, plan.receipts)

    assert {:ok, %{items: ^restored, receipts: ^receipts, result: :already_applied}} =
             PickupTransfers.plan(restored, receipts, {0, 0}, request, false)

    assert {:error, :stale_transfer} = ItemTransfers.plan(restored, receipts, {0, 0}, birth)
  end
end
