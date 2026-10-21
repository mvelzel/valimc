defmodule Valimc.ItemStepsTest do
  use ExUnit.Case, async: true
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.{ItemStack, Wire}
  alias Valimc.World.{ItemRecords, Items}

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
end
