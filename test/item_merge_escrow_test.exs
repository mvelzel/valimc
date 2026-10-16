defmodule Valimc.ItemMergeEscrowTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{ItemHandoffs, ItemLedger, ItemMergeEscrow, ItemMergeTransfer, Items}

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

  test "durable escrow removes owned visibility but retains exact return data and all receipts" do
    {items, request} = source()
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(items, {0, 0}, items.epoch, request)
    assert Items.records(escrowed) == [] and escrowed.views == %{}
    assert escrowed.ledger.sequence == 7 and escrowed.ledger.incoming == items.ledger.incoming
    assert escrowed.ledger.generations == %{}
    assert escrowed.ledger.outgoing.request == request
    assert {:error, :not_item_handoff} = ItemHandoffs.request(escrowed, {0, 0})
    restored = restored(escrowed)
    assert restored.ledger.outgoing == escrowed.ledger.outgoing
    assert {:error, :item_handoff_busy} = Items.create_record(restored, {0, 0}, request.donor)

    assert {:error, :item_merge_not_prepared} =
             ItemMergeEscrow.prepare(restored, {0, 0}, restored.epoch, request)
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

  test "native reverse-flow success restores an increased donor without clearing history" do
    {items, request} = source()
    stack = %{ItemStack.new("stone") | components: %{"minecraft:max_stack_size" => 99}}

    request = %{
      request
      | donor: %{request.donor | stack: stack},
        recipient: %{request.recipient | stack: %{stack | count: 65}}
    }

    assert {:ok, items} = Items.restore({0, 0}, [request.donor], items.ledger)
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(items, {0, 0}, items.epoch, request)
    assert {:ok, receipt} = ItemMergeTransfer.receipt(request, :applied)

    assert {:ok, complete, :applied} =
             ItemMergeEscrow.finish(restored(escrowed), {0, 0}, 7, receipt)

    assert [%{stack: %{count: 2}}] = Items.records(complete)
    assert complete.ledger.generations[request.donor.uuid] == 3
  end

  test "stale owner, item, generations, ordering and forged proof never change source authority" do
    {items, request} = source()

    for proposal <- [
          %{request | sequence: 6},
          %{request | source: {1, 0}},
          %{request | donor_generation: 1},
          %{request | donor: %{request.donor | stack: ItemStack.new("stone")}}
        ] do
      assert {:error, :item_merge_not_prepared} =
               ItemMergeEscrow.prepare(items, {0, 0}, items.epoch, proposal)
    end

    assert {:error, :item_merge_not_prepared} =
             ItemMergeEscrow.prepare(items, {0, 0}, make_ref(), request)

    assert {:ok, escrowed} = ItemMergeEscrow.prepare(items, {0, 0}, items.epoch, request)
    assert {:ok, digest} = ItemMergeTransfer.digest(request)

    for proof <- [nil, %{sequence: 7, digest: digest}, %{sequence: 0, digest: <<0::256>>}] do
      assert {:error, :item_merge_proof_conflict} =
               ItemMergeEscrow.finish(escrowed, {0, 0}, 7, proof)
    end

    assert {:ok, receipt} = ItemMergeTransfer.receipt(request, :applied)

    assert {:error, :item_merge_proof_conflict} =
             ItemMergeEscrow.finish(escrowed, {0, 0}, 8, receipt)
  end

  test "other births cannot consume the reserved donor return slot at the entity limit" do
    {items, request} = source()
    records = for n <- 10..264, do: %{request.donor | uuid: <<n::128>>, x: 8.5}
    assert {:ok, full} = Items.restore({0, 0}, [request.donor | records], items.ledger)
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(full, {0, 0}, full.epoch, request)
    assert map_size(escrowed.entries) == 255

    assert {:error, :item_count_limit} =
             Items.create(escrowed, {0, 0}, ItemStack.new("dirt"), {8.5, 64.0, 8.5})

    assert {:ok, proof} = ItemMergeTransfer.receipt(request, :rejected)

    assert {:ok, complete, :rejected} =
             ItemMergeEscrow.finish(restored(escrowed), {0, 0}, 7, proof)

    assert map_size(complete.entries) == 256
    assert complete.ledger.generations[request.donor.uuid] == 3
  end

  test "canonical ledger derives return byte capacity and refuses overbooked or tampered escrow" do
    {items, request} = source()
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(items, {0, 0}, items.epoch, request)
    outgoing = escrowed.ledger.outgoing
    assert outgoing.return_bytes > 256
    bad = %{escrowed.ledger | outgoing: %{outgoing | return_bytes: outgoing.return_bytes - 1}}
    assert {:error, :invalid_item_ledger} = ItemLedger.encode({0, 0}, [], %{}, bad)
    too_many = for n <- 10..265, do: %{request.donor | uuid: <<n::128>>, x: 8.5}

    assert {:error, :invalid_item_ledger} =
             ItemLedger.encode({0, 0}, too_many, %{}, escrowed.ledger)
  end

  test "large component births cannot spend bytes needed to return an escrowed donor" do
    {items, request} = source()

    component = %{
      "minecraft:custom_data" =>
        {:compound, %{"bytes" => {:byte_array, :binary.copy(<<17>>, 62_500)}}}
    }

    request = %{
      request
      | donor: %{request.donor | stack: %{request.donor.stack | components: component}},
        recipient: %{
          request.recipient
          | stack: %{request.recipient.stack | components: component}
        }
    }

    assert {:ok, items} = Items.restore({0, 0}, [request.donor], items.ledger)
    assert {:ok, escrowed} = ItemMergeEscrow.prepare(items, {0, 0}, items.epoch, request)

    filled =
      Enum.reduce_while(10..25, escrowed, fn n, current ->
        case Items.create_record(current, {0, 0}, %{request.donor | uuid: <<n::128>>, x: 8.5}) do
          {:ok, next, _} -> {:cont, next}
          {:error, :item_byte_limit} -> {:halt, current}
        end
      end)

    assert map_size(filled.entries) == 7
    assert Items.return_capacity?(filled)
    assert {:ok, proof} = ItemMergeTransfer.receipt(request, :rejected)
    assert {:ok, returned, :rejected} = ItemMergeEscrow.finish(restored(filled), {0, 0}, 7, proof)
    assert map_size(returned.entries) == 8 and returned.bytes <= 524_288
    assert {:ok, {_, id, _}} = Items.find(returned, request.donor.uuid)
    assert returned.entries[id].stack == request.donor.stack
  end
end
