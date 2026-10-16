defmodule Valimc.ItemStepsTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.World.{ItemRecords, ItemReplication, Items}

  defp initial do
    {:ok, items, {epoch, id, revision}} =
      Items.create(Items.new(), {0, 0}, ItemStack.new("stone", 3), {0.5, 64.5, 0.5})

    step = %{
      id: id,
      revision: revision,
      position: {16.5, 65.0, 0.5},
      motion: %ItemMotionState{velocity: {0.3, -0.04, 0.0}, age: 1, pickup_delay: 39}
    }

    {items, epoch, step}
  end

  defp names(packets), do: Enum.map(packets, fn {id, _} -> Data.name(:play, :clientbound, id) end)

  test "accepted steps retain identity, fresh fences and saved state across chunk movement" do
    {items, epoch, step} = initial()
    original = hd(Items.records(items))
    assert {:ok, next, [{^epoch, id, 2}]} = Items.advance(items, {0, 0}, epoch, [step])
    assert id == step.id and map_size(next.entries) == 1
    assert next.views[id].chunk == {1, 0}
    assert [record] = Items.records(next)
    assert record.uuid == original.uuid and record.stack == original.stack
    assert {record.x, record.y, record.z} == step.position and record.motion == step.motion
    assert {:ok, bytes} = ItemRecords.encode({0, 0}, [record])
    assert {:ok, %{records: [^record]}} = ItemRecords.decode(bytes, {0, 0})
    assert Items.replace(next, epoch, id, 1, ItemStack.new("egg")) == {:error, :stale_item}
    assert {:ok, replaced, _} = Items.replace(next, epoch, id, 2, ItemStack.new("egg"))
    assert replaced.entries[id].no_gravity == false
    {_, <<5, 8, 0, _::binary>>} = Wire.take_varint(elem(replaced.views[id].metadata, 1))

    assert {:ok, ^next, [{^epoch, ^id, 2}]} =
             Items.advance(next, {0, 0}, epoch, [%{step | revision: 2}])
  end

  test "position precedes velocity; later movement avoids repeated metadata and fresh tracking uses current spawn" do
    {items, epoch, step} = initial()
    {observer, _} = ItemReplication.reconcile(ItemReplication.new(), items.views)
    {:ok, next, _} = Items.advance(items, {0, 0}, epoch, [step])
    {observer, packets} = ItemReplication.reconcile(observer, next.views)
    assert names(packets) == ["entity_position_sync", "set_entity_motion", "set_entity_data"]
    step2 = %{step | revision: 2, position: {17.0, 64.9, 0.5}, motion: %{step.motion | age: 2}}
    {:ok, latest, _} = Items.advance(next, {0, 0}, epoch, [step2])
    {observer, packets} = ItemReplication.reconcile(observer, latest.views)
    assert names(packets) == ["entity_position_sync", "set_entity_motion"]
    assert {^observer, []} = ItemReplication.reconcile(observer, latest.views)
    {_, [spawn, _]} = ItemReplication.reconcile(ItemReplication.new(), latest.views)
    assert spawn == latest.views[step.id].spawn
    assert spawn != items.views[step.id].spawn

    {behind, _} = ItemReplication.reconcile(ItemReplication.new(), items.views)
    {_, [position | _]} = ItemReplication.reconcile(behind, latest.views)
    assert position == latest.views[step.id].position
    refute position == next.views[step.id].position

    age_only = %{step2 | revision: 3, motion: %{step2.motion | age: 3}}
    {:ok, aged, _} = Items.advance(latest, {0, 0}, epoch, [age_only])
    assert {^observer, []} = ItemReplication.reconcile(observer, aged.views)
  end

  test "invalid, duplicate, stale and cross-region batches cannot publish a partial result" do
    {items, epoch, step} = initial()

    for steps <- [
          [],
          List.duplicate(step, 33),
          [step, step],
          [nil],
          [step, %{step | id: -1}],
          [%{step | revision: 0}],
          [%{step | position: {128.0, 65, 0}}],
          [%{step | motion: nil}]
        ] do
      assert {:error, _} = Items.advance(items, {0, 0}, epoch, steps)
    end

    assert {:error, :stale_region} = Items.advance(items, {0, 0}, make_ref(), [step])
    assert hd(Items.records(items)).x == 0.5 and items.views[step.id].revision == 1
  end

  test "move deltas stay small when item metadata contains a large shared binary" do
    {items, epoch, step} = initial()

    stack = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"bytes" => {:byte_array, :binary.copy(<<12>>, 60_000)}}}
        }
    }

    {:ok, items, {_, _, revision}} = Items.replace(items, epoch, step.id, 1, stack)
    {observer, _} = ItemReplication.reconcile(ItemReplication.new(), items.views)
    step = %{step | revision: revision, motion: %{step.motion | no_gravity: true}}
    {:ok, next, _} = Items.advance(items, {0, 0}, epoch, [step])
    {_, packets} = ItemReplication.reconcile(observer, next.views)
    assert names(packets) == ["entity_position_sync", "set_entity_motion"]
    assert Enum.sum(Enum.map(packets, &Items.packet_bytes/1)) < 100
    {:ok, empty} = Items.remove(next, epoch, step.id, revision + 1)
    assert empty.bytes == 0 and empty.views == %{}
  end

  test "a full32-step batch commits every revision in input order without changing item counts" do
    {handles, items} =
      Enum.map_reduce(1..32, Items.new(), fn n, items ->
        {:ok, next, handle} =
          Items.create(items, {0, 0}, ItemStack.new("stone", n), {n + 0.5, 64.5, 0.5})

        {handle, next}
      end)

    steps =
      Enum.map(handles, fn {_, id, revision} ->
        %{
          id: id,
          revision: revision,
          position: {0.5, 65.0, 0.5},
          motion: %ItemMotionState{no_gravity: true}
        }
      end)

    assert {:ok, next, updated} = Items.advance(items, {0, 0}, items.epoch, steps)
    assert Enum.map(updated, &elem(&1, 1)) == Enum.map(handles, &elem(&1, 1))
    assert Enum.all?(updated, &(elem(&1, 2) == 2))
    assert Enum.sort(Enum.map(Items.records(next), & &1.stack.count)) == Enum.to_list(1..32)
  end
end
