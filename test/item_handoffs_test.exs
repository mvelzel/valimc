defmodule Valimc.ItemHandoffsTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.{EntityPackets, ItemStack}
  alias Valimc.World.{ItemHandoffs, ItemLedger, Items}

  defp record(n, x \\ 0.5),
    do: %{
      uuid: <<n::128>>,
      x: x,
      y: 65.5,
      z: 0.5,
      stack: ItemStack.new("stone", 3),
      motion: %ItemMotionState{velocity: {0.2, -0.04, 0.1}, pickup_delay: 20}
    }

  defp departure(items, source, destination, uuid, x) do
    {:ok, {epoch, id, revision}} = Items.find(items, uuid)

    step = %{
      id: id,
      revision: revision,
      position: {x, 65.5, 0.5},
      motion: %ItemMotionState{velocity: {0.3, -0.08, 0.1}, age: 2, pickup_delay: 18}
    }

    ItemHandoffs.depart(items, source, epoch, destination, [step])
  end

  defp recovered(items, key) do
    {:ok, bytes} = ItemLedger.encode(key, Items.records(items), %{}, items.ledger)
    {:ok, snapshot} = ItemLedger.decode(bytes, key)
    {:ok, restored} = Items.restore(key, snapshot.records, snapshot.ledger)
    restored
  end

  defp clear(items, key) do
    {:ok, transfer} = ItemHandoffs.request(items, key)
    {:ok, digest} = ItemHandoffs.digest(transfer.destination, transfer)
    ItemHandoffs.finish(items, key, transfer.sequence, digest)
  end

  test "recovered withdrawal, adoption and clearance conserve UUID, stack, motion and retries" do
    original = record(1)
    {:ok, source} = Items.restore({0, 0}, [original])
    {:ok, withdrawn, transfer} = departure(source, {0, 0}, {1, 0}, original.uuid, 128.5)
    assert Items.records(withdrawn) == [] and withdrawn.views == %{}
    assert withdrawn.ledger.sequence == 1
    assert {:ok, ^transfer} = ItemHandoffs.request(recovered(withdrawn, {0, 0}), {0, 0})
    assert {:ok, adopted, :applied} = ItemHandoffs.accept(Items.new(), {1, 0}, transfer)
    assert [moved] = Items.records(adopted)
    assert moved.uuid == original.uuid and moved.stack == original.stack and moved.x == 128.5
    assert moved.motion == hd(transfer.records).motion
    assert adopted.ledger.generations == %{original.uuid => 1}
    assert [view] = Map.values(adopted.views)
    assert view.ownership_generation == 1
    entry = adopted.entries[view.entity_id]
    assert entry.entity.velocity == moved.motion.velocity and entry.no_gravity == false
    assert view.spawn == binary_packet(EntityPackets.spawn_item(entry.entity))

    assert view.motion ==
             binary_packet(EntityPackets.motion(view.entity_id, moved.motion.velocity))

    restored = recovered(adopted, {1, 0})
    assert {:ok, ^restored, :already_applied} = ItemHandoffs.accept(restored, {1, 0}, transfer)
    assert {:ok, cleared} = clear(recovered(withdrawn, {0, 0}), {0, 0})
    assert cleared.ledger.sequence == 1 and cleared.ledger.outgoing == nil

    assert {:error, :missing_item_handoff} =
             ItemHandoffs.request(recovered(cleared, {0, 0}), {0, 0})
  end

  test "receipts prevent resurrection after onward movement; returning before clearance retries" do
    {:ok, source} = Items.restore({0, 0}, [record(1)])
    {:ok, a, first} = departure(source, {0, 0}, {1, 0}, <<1::128>>, 128.5)
    {:ok, b, :applied} = ItemHandoffs.accept(Items.new(), {1, 0}, first)
    {:ok, b, second} = departure(b, {1, 0}, {0, 0}, <<1::128>>, 0.5)
    assert {:ok, ^b, :already_applied} = ItemHandoffs.accept(b, {1, 0}, first)
    assert {:error, :item_handoff_busy} = ItemHandoffs.accept(a, {0, 0}, second)
    {:ok, a} = clear(a, {0, 0})
    assert {:ok, a, :applied} = ItemHandoffs.accept(a, {0, 0}, second)
    assert a.ledger.generations == %{<<1::128>> => 2}
    assert {:ok, b} = clear(b, {1, 0})
    assert b.ledger.incoming[{0, 0}].sequence == 1
    assert {:ok, b, :already_applied} = ItemHandoffs.accept(recovered(b, {1, 0}), {1, 0}, first)
    assert Items.records(b) == []
    {:ok, a, third} = departure(a, {0, 0}, {1, 0}, <<1::128>>, 128.5)
    assert third.sequence == 2 and third.generations == %{<<1::128>> => 3}
    assert {:ok, b, :applied} = ItemHandoffs.accept(b, {1, 0}, third)
    assert {:error, :stale_item_handoff} = ItemHandoffs.accept(b, {1, 0}, first)
    assert {:ok, _} = clear(a, {0, 0})
  end

  defp binary_packet({id, bytes}), do: {id, IO.iodata_to_binary(bytes)}
end
