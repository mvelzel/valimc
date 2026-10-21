defmodule Valimc.ItemMergeEscrowTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{ItemLedger, ItemMergeEscrow, ItemMergeTransfer, Items}

  defp source do
    donor = %{
      uuid: <<1::128>>,
      x: 127.9,
      y: 64.0,
      z: 8.5,
      stack: ItemStack.new("stone", 2),
      motion: %ItemMotionState{age: 30, pickup_delay: 10}
    }

    recipient = %{
      donor
      | uuid: <<2::128>>,
        x: 128.1,
        stack: ItemStack.new("stone", 3),
        motion: %ItemMotionState{age: 100, pickup_delay: 2}
    }

    request = %{
      source: {0, 0},
      destination: {1, 0},
      sequence: 7,
      permit: <<3::128>>,
      donor: donor,
      recipient: recipient,
      donor_generation: 2,
      recipient_generation: 4
    }

    ledger = %ItemLedger{
      sequence: 6,
      generations: %{donor.uuid => 2},
      incoming: %{{-1, 0} => %{sequence: 2, digest: <<19::256>>}}
    }

    {:ok, items} = Items.restore({0, 0}, [donor], ledger)
    {items, request}
  end

  defp restored(items) do
    receipts = %{<<9::128>> => %{sequence: 10, digest: <<11::256>>}}
    assert {:ok, bytes} = ItemLedger.encode({0, 0}, Items.records(items), receipts, items.ledger)
    assert {:ok, decoded} = ItemLedger.decode(bytes, {0, 0})
    assert decoded.receipts == receipts and decoded.ledger == items.ledger
    assert {:ok, restored} = Items.restore({0, 0}, decoded.records, decoded.ledger)
    assert restored.epoch != items.epoch
    restored
  end

  test "applied proof clears escrow once; rejected proof restores one newer ownership generation" do
    {items, request} = source()
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(items, {0, 0}, items.epoch, request)

    for result <- [:applied, :rejected] do
      recovered = restored(escrowed)
      assert {:ok, receipt} = ItemMergeTransfer.receipt(request, result)
      assert {:ok, complete, ^result} = ItemMergeEscrow.finish(recovered, {0, 0}, 7, receipt)
      assert complete.ledger.outgoing == nil and complete.ledger.sequence == 7
      assert complete.ledger.incoming == items.ledger.incoming

      assert {:error, :item_merge_proof_conflict} =
               ItemMergeEscrow.finish(complete, {0, 0}, 7, receipt)

      if result == :applied do
        assert Items.records(complete) == [] and complete.ledger.generations == %{}
      else
        assert Items.records(complete) == [request.donor]
        assert complete.ledger.generations == %{request.donor.uuid => 3}
        assert [view] = Map.values(complete.views)
        assert view.ownership_generation == 3
      end

      restored(complete)
    end
  end
end
