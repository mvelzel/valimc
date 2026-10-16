defmodule Valimc.ItemHandoffsTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.{EntityPackets, ItemStack}
  alias Valimc.World.{ItemHandoffs, ItemLedger, ItemReplication, Items}

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

  test "full owners exchange cohorts while independently retaining outgoing delivery state" do
    {:ok, a} = Items.restore({0, 0}, Enum.map(1..256, &record/1))
    {:ok, b} = Items.restore({1, 0}, Enum.map(257..512, &record(&1, 128.5)))

    steps = fn items, x ->
      items.entries
      |> Enum.take(32)
      |> Enum.map(fn {id, entry} ->
        %{id: id, revision: entry.revision, position: {x, 65.5, 0.5}, motion: entry.motion}
      end)
    end

    {:ok, a, ab} = ItemHandoffs.depart(a, {0, 0}, a.epoch, {1, 0}, steps.(a, 128.5))
    {:ok, b, ba} = ItemHandoffs.depart(b, {1, 0}, b.epoch, {0, 0}, steps.(b, 0.5))
    assert {:ok, a, :applied} = ItemHandoffs.accept(a, {0, 0}, ba)
    assert {:ok, b, :applied} = ItemHandoffs.accept(b, {1, 0}, ab)
    assert map_size(a.entries) == 256 and map_size(b.entries) == 256
    assert a.ledger.outgoing != nil and b.ledger.outgoing != nil
    assert {:ok, a} = clear(recovered(a, {0, 0}), {0, 0})
    assert {:ok, b} = clear(recovered(b, {1, 0}), {1, 0})
    uuids = Enum.map(Items.records(a) ++ Items.records(b), & &1.uuid)
    assert length(Enum.uniq(uuids)) == 512
  end

  test "failed cohorts, stale handles, sequence overflow and conflicting receipts stay atomic" do
    {:ok, a} = Items.restore({0, 0}, [record(1), record(2)])
    {:ok, {epoch, id, rev}} = Items.find(a, <<1::128>>)
    step = %{id: id, revision: rev, position: {128.5, 65.5, 0.5}, motion: %ItemMotionState{}}
    assert {:error, :stale_region} = ItemHandoffs.depart(a, {0, 0}, make_ref(), {1, 0}, [step])

    assert {:error, :stale_item} =
             ItemHandoffs.depart(a, {0, 0}, epoch, {1, 0}, [%{step | revision: 9}])

    assert {:error, :invalid_item_steps} =
             ItemHandoffs.depart(a, {0, 0}, epoch, {1, 0}, [step, step])

    assert {:error, :invalid_item_step} =
             ItemHandoffs.depart(a, {0, 0}, epoch, {1, 0}, [
               %{step | position: {256.5, 65.5, 0.5}}
             ])

    assert {:error, :item_handoff_sequence_limit} =
             ItemHandoffs.depart(
               %{a | ledger: %{a.ledger | sequence: 18_446_744_073_709_551_615}},
               {0, 0},
               epoch,
               {1, 0},
               [step]
             )

    assert {:ok, withdrawn, transfer} = ItemHandoffs.depart(a, {0, 0}, epoch, {1, 0}, [step])

    assert {:error, :item_handoff_busy} =
             ItemHandoffs.depart(withdrawn, {0, 0}, epoch, {1, 0}, [step])

    assert {:error, :stale_item_handoff} = ItemHandoffs.finish(withdrawn, {0, 0}, 1, <<0::256>>)
    {:ok, b, :applied} = ItemHandoffs.accept(Items.new(), {1, 0}, transfer)
    conflict = %{transfer | records: [%{hd(transfer.records) | stack: ItemStack.new("egg", 3)}]}
    assert {:error, :item_handoff_conflict} = ItemHandoffs.accept(b, {1, 0}, conflict)
    assert Items.records(a) == [record(1), record(2)]
  end

  test "adoption bounds and outbound reservation failures do not partly insert a cohort" do
    {:ok, a} = Items.restore({0, 0}, [record(1), record(2)])

    steps =
      Enum.map(a.entries, fn {id, e} ->
        %{id: id, revision: e.revision, position: {128.5, 65.5, 0.5}, motion: e.motion}
      end)

    {:ok, _, transfer} = ItemHandoffs.depart(a, {0, 0}, a.epoch, {1, 0}, steps)
    {:ok, full} = Items.restore({1, 0}, Enum.map(10..264, &record(&1, 128.5)))
    assert {:error, :item_count_limit} = ItemHandoffs.accept(full, {1, 0}, transfer)
    assert map_size(full.entries) == 255 and full.ledger.incoming == %{}
    incoming = Map.new(1..4096, fn n -> {{n, 1}, %{sequence: 1, digest: <<n::256>>}} end)
    capped = %{Items.new() | ledger: %ItemLedger{incoming: incoming}}
    assert {:error, :item_handoff_source_limit} = ItemHandoffs.accept(capped, {1, 0}, transfer)

    for invalid <- [
          %{transfer | destination: {0, 0}},
          %{transfer | generations: %{}},
          %{transfer | sequence: 0},
          Map.put(transfer, :extra, true),
          nil
        ],
        do: assert(match?({:error, _}, ItemHandoffs.accept(Items.new(), {1, 0}, invalid)))
  end

  test "torn observer samples choose newer ownership before spawning or replacing runtime IDs" do
    {:ok, a} = Items.restore({0, 0}, [record(1)])
    {:ok, _, transfer} = departure(a, {0, 0}, {1, 0}, <<1::128>>, 128.5)
    {:ok, b, :applied} = ItemHandoffs.accept(Items.new(), {1, 0}, transfer)
    [old_id] = Map.keys(a.views)
    [new_id] = Map.keys(b.views)
    torn = Map.merge(a.views, b.views)
    {fresh, packets} = ItemReplication.reconcile(ItemReplication.new(), torn)
    assert Map.keys(fresh.tracked) == [new_id] and length(packets) == 2
    {old, _} = ItemReplication.reconcile(ItemReplication.new(), a.views)
    {next, packets} = ItemReplication.reconcile(old, torn)
    assert Map.keys(next.tracked) == [new_id] and length(packets) == 3
    refute Map.has_key?(next.tracked, old_id)
    assert {^next, []} = ItemReplication.reconcile(next, torn)
  end

  defp binary_packet({id, bytes}), do: {id, IO.iodata_to_binary(bytes)}
end
