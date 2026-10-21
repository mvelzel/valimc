defmodule Valimc.ItemMergesTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{ItemLedger, ItemMerges, Items}

  defp record(n, count, extra \\ %{}) do
    Map.merge(
      %{
        uuid: <<n::128>>,
        x: 8.5,
        y: 64.0,
        z: 8.5,
        stack: ItemStack.new("stone", count),
        motion: %ItemMotionState{age: n * 10, pickup_delay: n, velocity: {n / 10, 0.0, 0.0}}
      },
      extra
    )
  end

  defp pair(items, a, b) do
    {:ok, {_, ai, ar}} = Items.find(items, <<a::128>>)
    {:ok, {_, bi, br}} = Items.find(items, <<b::128>>)
    %{a: {ai, ar}, b: {bi, br}}
  end

  test "merge retains recipient identity, velocity, components and generation; removes donor atomically" do
    a = record(1, 2)
    b = record(2, 3)
    ledger = %ItemLedger{generations: %{a.uuid => 4, b.uuid => 7}}
    {:ok, items} = Items.restore({0, 0}, [a, b], ledger)
    proposal = pair(items, 1, 2)
    assert {:ok, next, [change]} = ItemMerges.plan(items, items.epoch, [proposal])
    assert change.removed == elem(proposal.a, 0) and change.donor == nil
    assert [saved] = Items.records(next)
    assert saved.uuid == b.uuid and saved.stack.count == 5
    assert saved.motion == %{b.motion | age: 10, pickup_delay: 2}
    assert next.ledger.generations == %{b.uuid => 7}
    assert length(Items.records(items)) == 2
    assert {:error, :stale_item} = ItemMerges.plan(next, next.epoch, [proposal])
    assert {:ok, bytes} = ItemLedger.encode({0, 0}, Items.records(next), %{}, next.ledger)
    assert {:ok, %{records: [^saved], ledger: restored}} = ItemLedger.decode(bytes, {0, 0})
    assert restored == next.ledger
  end

  test "batch refuses stale, repeated, oversized, incompatible and out-of-range pairs without partial state" do
    {:ok, items} = Items.restore({0, 0}, for(n <- 1..4, do: record(n, 2)))
    first = pair(items, 1, 2)
    second = pair(items, 3, 4)

    assert {:error, :stale_item} =
             ItemMerges.plan(items, items.epoch, [first, %{second | b: {elem(second.b, 0), 999}}])

    assert {:error, :invalid_item_merges} = ItemMerges.plan(items, items.epoch, [first, first])
    assert {:error, :invalid_item_merges} = ItemMerges.plan(items, make_ref(), [first])

    assert {:error, :invalid_item_merges} =
             ItemMerges.plan(items, items.epoch, List.duplicate(first, 33))

    assert {:error, :invalid_item_merges} = ItemMerges.plan(items, items.epoch, [%{}])
    assert length(Items.records(items)) == 4

    for b <- [
          record(2, 2, %{x: 9.25}),
          record(2, 2, %{y: 64.25}),
          record(2, 63),
          record(2, 2, %{stack: ItemStack.new("egg", 2)})
        ] do
      {:ok, other} = Items.restore({0, 0}, [record(1, 2), b])
      assert {:error, _} = ItemMerges.plan(other, other.epoch, [pair(other, 1, 2)])
    end
  end
end
