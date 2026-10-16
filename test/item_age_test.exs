defmodule Valimc.ItemAgeTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemLedger, ItemReplication, Items}

  test "counter-only advances preserve retained wire binaries and ownership generations" do
    record = %{
      uuid: <<1::128>>,
      x: 0.5,
      y: 65.5,
      z: 0.5,
      stack: ItemStack.new("stone", 3),
      motion: %ItemMotionState{velocity: {0.1, -0.2, 0.0}, age: 5998, pickup_delay: 2}
    }

    ledger = %ItemLedger{generations: %{record.uuid => 4}}
    {:ok, items} = Items.restore({0, 0}, [record], ledger)
    [id] = Map.keys(items.entries)
    view = items.views[id]
    {observer, _} = ItemReplication.reconcile(ItemReplication.new(), items.views)
    {aged, []} = Items.age(items)
    assert aged.entries[id].motion == %{record.motion | age: 5999, pickup_delay: 1}
    assert aged.views[id] == %{view | revision: 2, pickup_delay: 1}
    assert aged.bytes == items.bytes and aged.ledger == ledger
    assert aged.entries[id].physical_revision == items.entries[id].physical_revision
    assert {^observer, []} = ItemReplication.reconcile(observer, aged.views)
    {expired, [handle]} = Items.age(aged)
    assert handle == {items.epoch, id, 3}
    assert expired.entries[id].motion == %{record.motion | age: 6000, pickup_delay: 0}
    assert expired.views[id] == %{view | revision: 3, pickup_delay: 0, merge_open: false}
    assert {:ok, empty} = Items.remove(expired, items.epoch, id, 3)
    assert empty.ledger.generations == %{}
  end

  test "full-precision motion changes invalidate physics even if their wire packets are equal" do
    record = %{
      uuid: <<1::128>>,
      x: 0.5,
      y: 65.5,
      z: 0.5,
      stack: ItemStack.new("stone", 3),
      motion: %ItemMotionState{no_gravity: true}
    }

    {:ok, items} = Items.restore({0, 0}, [record])
    [id] = Map.keys(items.entries)

    step = %{
      id: id,
      revision: 1,
      position: {0.5, 65.5, 0.5},
      motion: %{record.motion | velocity: {1.0e-12, 0.0, 0.0}}
    }

    assert {:ok, next, _} = Items.advance(items, {0, 0}, items.epoch, [step])
    assert next.views[id].motion_revision == items.views[id].motion_revision
    assert next.entries[id].physical_revision == items.entries[id].physical_revision + 1
    assert next.views[id].physical_revision == next.entries[id].physical_revision
  end

  test "infinite-age and permanent-delay sentinels never allocate counter revisions once unchanged" do
    record = %{
      uuid: <<1::128>>,
      x: 0.5,
      y: 65.5,
      z: 0.5,
      stack: ItemStack.new("stone", 3),
      motion: %ItemMotionState{age: -32_768, pickup_delay: 32_767}
    }

    {:ok, items} = Items.restore({0, 0}, [record])
    assert {^items, []} = Items.age(items)
    assert %{age: -5999, pickup_delay: 0} = ItemMotionState.tick(%ItemMotionState{age: -6000})
  end
end
