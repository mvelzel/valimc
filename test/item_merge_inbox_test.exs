defmodule Valimc.ItemMergeInboxTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Protocol.ItemStack}

  alias Valimc.World.{
    ItemHandoffs,
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

  test "expiry, moved targets, changed stacks/generations and terminal retries restore the donor once" do
    {source, dest, req} = fixture()
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(source, req.source, source.epoch, req)
    {:ok, {epoch, id, revision}} = Items.find(dest, req.recipient.uuid)

    {:ok, moved, [_]} =
      Items.advance(dest, req.destination, epoch, [
        %{id: id, revision: revision, position: {129.5, 64.0, 8.5}, motion: req.recipient.motion}
      ])

    {:ok, changed, _} = Items.replace(dest, epoch, id, revision, ItemStack.new("stone", 4))
    returned = %{dest | ledger: %{dest.ledger | generations: %{req.recipient.uuid => 6}}}

    for {items, permission} <- [{dest, false}, {moved, true}, {changed, true}, {returned, true}] do
      assert {:ok, committed, :rejected} =
               ItemMergeInbox.apply(items, req.destination, req, permission)

      assert Items.records(committed) == Items.records(items)

      assert {:ok, ^committed, :already_rejected} =
               ItemMergeInbox.apply(committed, req.destination, req, true)

      assert {:ok, finished, :rejected} =
               ItemMergeEscrow.finish(
                 escrowed,
                 req.source,
                 7,
                 committed.ledger.incoming[req.source]
               )

      assert Items.records(finished) == [req.donor]
      assert finished.ledger.generations[req.donor.uuid] == 3
    end
  end

  test "fresh target counters determine native age/delay without changing the prepared donor amount" do
    {_source, dest, req} = fixture()
    {:ok, {epoch, id, revision}} = Items.find(dest, req.recipient.uuid)
    motion = %{req.recipient.motion | age: 10, pickup_delay: 20}

    {:ok, dest, [_]} =
      Items.advance(dest, req.destination, epoch, [
        %{
          id: id,
          revision: revision,
          position: {req.recipient.x, req.recipient.y, req.recipient.z},
          motion: motion
        }
      ])

    assert {:ok, committed, :applied} = ItemMergeInbox.apply(dest, req.destination, req, true)
    assert [%{stack: %{count: 5}, motion: motion}] = Items.records(committed)
    assert motion.age == 10 and motion.pickup_delay == 20
  end

  test "custom99 reverse flow conserves66 across a64 recipient and a2 restored donor" do
    {source, dest, req} = fixture()
    stack = %{ItemStack.new("stone") | components: %{"minecraft:max_stack_size" => 99}}

    req = %{
      req
      | donor: %{req.donor | stack: stack},
        recipient: %{req.recipient | stack: %{stack | count: 65}}
    }

    {:ok, source} = Items.restore(req.source, [req.donor], source.ledger)
    {:ok, dest} = Items.restore(req.destination, [req.recipient], dest.ledger)
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(source, req.source, source.epoch, req)
    assert {:ok, dest, :applied} = ItemMergeInbox.apply(dest, req.destination, req, true)

    assert {:ok, source, :applied} =
             ItemMergeEscrow.finish(escrowed, req.source, 7, dest.ledger.incoming[req.source])

    assert [%{stack: %{count: 64}}] = Items.records(dest)
    assert [%{stack: %{count: 2}}] = Items.records(source)
    recover(req.destination, dest)
    recover(req.source, source)
  end

  test "receipt capacity is reserved before withdrawal and cannot rewind existing source history" do
    {_source, dest, req} = fixture()

    assert {:ok, %{records: [_], ledger: ledger}} =
             ItemLedger.decode(
               elem(ItemLedger.encode(req.destination, Items.records(dest), %{}, dest.ledger), 1),
               req.destination
             )

    assert ledger.incoming[req.source] == %{sequence: 0, digest: <<0::256>>}

    assert {:error, :item_merge_reservation_required} =
             ItemMergeInbox.apply(
               %{dest | ledger: %{dest.ledger | incoming: %{}}},
               req.destination,
               req,
               true
             )

    assert {:ok, committed, :applied} = ItemMergeInbox.apply(dest, req.destination, req, true)

    assert {:ok, incoming, :existing} =
             OwnerItemReceipts.reserve(committed.ledger.incoming, req.source, req.destination)

    assert incoming == committed.ledger.incoming

    assert {:error, :item_merge_receipt_conflict} =
             ItemMergeInbox.apply(committed, req.destination, %{req | permit: <<4::128>>}, true)

    assert {:error, :stale_item_merge} =
             ItemMergeInbox.apply(committed, req.destination, %{req | sequence: 6}, true)

    assert {:error, :invalid_item_receipt_source} =
             OwnerItemReceipts.reserve(%{}, req.source, req.source)

    full = Map.new(1..4096, &{{-&1, 0}, %{sequence: 0, digest: <<0::256>>}})

    assert {:error, :item_handoff_source_limit} =
             OwnerItemReceipts.reserve(full, req.source, req.destination)

    assert {:ok, ^full, :existing} = OwnerItemReceipts.reserve(full, {-1, 0}, req.destination)

    assert {:error, :invalid_item_receipt} =
             OwnerItemReceipts.reserve(
               %{req.source => %{sequence: 0, digest: <<1::256>>}},
               req.source,
               req.destination
             )
  end

  test "reserved region receipt also permits the existing native owner handoff lane" do
    {source, dest, req} = fixture()
    {:ok, {epoch, id, revision}} = Items.find(source, req.donor.uuid)
    step = %{id: id, revision: revision, position: {128.5, 64.0, 10.5}, motion: req.donor.motion}

    assert {:ok, _, request} =
             ItemHandoffs.depart(source, req.source, epoch, req.destination, [step])

    assert {:ok, accepted, :applied} = ItemHandoffs.accept(dest, req.destination, request)
    assert accepted.ledger.incoming[req.source].sequence == 7
    assert length(Items.records(accepted)) == 2
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
