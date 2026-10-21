defmodule Valimc.ItemMergeInboxTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Protocol.ItemStack}

  alias Valimc.World.{
    ItemLedger,
    ItemMergeEscrow,
    ItemMergeInbox,
    ItemMergeTransfer,
    Items,
    OwnerItemReceipts
  }

  defp fixture do
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

    req = %{
      source: {0, 0},
      destination: {1, 0},
      sequence: 7,
      permit: <<3::128>>,
      donor: donor,
      recipient: recipient,
      donor_generation: 2,
      recipient_generation: 4
    }

    {:ok, source} =
      Items.restore(req.source, [donor], %ItemLedger{sequence: 6, generations: %{donor.uuid => 2}})

    {:ok, incoming, :reserved} = OwnerItemReceipts.reserve(%{}, req.source, req.destination)

    {:ok, destination} =
      Items.restore(req.destination, [recipient], %ItemLedger{
        incoming: incoming,
        generations: %{recipient.uuid => 4}
      })

    {source, destination, req}
  end

  defp recover(key, items) do
    {:ok, bytes} = ItemLedger.encode(key, Items.records(items), %{}, items.ledger)
    {:ok, saved} = ItemLedger.decode(bytes, key)
    {:ok, restored} = Items.restore(key, saved.records, saved.ledger)
    restored
  end

  test "both recovery cuts and duplicate delivery conserve a single native merge" do
    {source, dest, req} = fixture()
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(source, req.source, source.epoch, req)
    escrowed = recover(req.source, escrowed)
    dest = recover(req.destination, dest)
    assert {:ok, committed, :applied} = ItemMergeInbox.apply(dest, req.destination, req, true)
    assert [%{uuid: uuid, stack: %{count: 5}, motion: motion}] = Items.records(committed)
    assert uuid == req.recipient.uuid and motion.age == 30 and motion.pickup_delay == 10
    committed = recover(req.destination, committed)

    assert {:ok, ^committed, :already_applied} =
             ItemMergeInbox.apply(committed, req.destination, req, false)

    proof = committed.ledger.incoming[req.source]
    assert {:ok, finished, :applied} = ItemMergeEscrow.finish(escrowed, req.source, 7, proof)
    assert Items.records(recover(req.source, finished)) == []
    assert committed.ledger.generations == %{req.recipient.uuid => 4}
  end

  test "two donor owners racing one recipient reject a stale plan and can retry without loss" do
    {source, dest, req} = fixture()
    req = %{req | donor: %{req.donor | z: 0.1}, recipient: %{req.recipient | z: 0.1}}
    {:ok, source} = Items.restore(req.source, [req.donor], source.ledger)
    {:ok, dest} = Items.restore(req.destination, [req.recipient], dest.ledger)

    other = %{
      req
      | source: {1, -1},
        permit: <<9::128>>,
        donor_generation: 0,
        donor: %{req.donor | uuid: <<4::128>>, x: 128.1, z: -0.1}
    }

    {:ok, second} = Items.restore(other.source, [other.donor], %ItemLedger{sequence: 6})

    {:ok, incoming, :reserved} =
      OwnerItemReceipts.reserve(dest.ledger.incoming, other.source, req.destination)

    dest = %{dest | ledger: %{dest.ledger | incoming: incoming}}
    assert {:ok, first_escrow} = ItemMergeEscrow.prepare(source, req.source, source.epoch, req)

    assert {:ok, second_escrow} =
             ItemMergeEscrow.prepare(second, other.source, second.epoch, other)

    assert {:ok, dest, :applied} = ItemMergeInbox.apply(dest, req.destination, req, true)
    assert {:ok, dest, :rejected} = ItemMergeInbox.apply(dest, other.destination, other, true)

    assert {:ok, :rejected} =
             ItemMergeTransfer.receipt_result(other, dest.ledger.incoming[other.source])

    assert {:ok, source, :applied} =
             ItemMergeEscrow.finish(first_escrow, req.source, 7, dest.ledger.incoming[req.source])

    assert {:ok, second, :rejected} =
             ItemMergeEscrow.finish(
               second_escrow,
               other.source,
               7,
               dest.ledger.incoming[other.source]
             )

    assert Items.records(source) == []
    assert [%{stack: %{count: 5}} = recipient] = Items.records(dest)
    assert [%{stack: %{count: 2}}] = Items.records(second)

    retry = %{other | sequence: 8, permit: <<10::128>>, donor_generation: 1, recipient: recipient}
    assert {:ok, escrow} = ItemMergeEscrow.prepare(second, retry.source, second.epoch, retry)
    assert {:ok, dest, :applied} = ItemMergeInbox.apply(dest, retry.destination, retry, true)

    assert {:ok, second, :applied} =
             ItemMergeEscrow.finish(escrow, retry.source, 8, dest.ledger.incoming[retry.source])

    assert Items.records(second) == []
    assert [%{stack: %{count: 7}}] = Items.records(recover(retry.destination, dest))
    assert dest.ledger.incoming[req.source].sequence == 7
    assert dest.ledger.incoming[other.source].sequence == 8
  end
end
