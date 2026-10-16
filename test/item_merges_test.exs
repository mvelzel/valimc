defmodule Valimc.ItemMergesTest do
  use ExUnit.Case, async: true
  alias Valimc.{ItemMotionState, Physics.ItemMerge, Protocol.ItemStack}
  alias Valimc.World.{ItemHandoffs, ItemLedger, ItemMerges, Items}

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

  test "effective identity merges explicit defaults but preserves the surviving raw patch" do
    a = record(1, 2)

    b =
      record(2, 2, %{
        stack: %{ItemStack.new("stone", 2) | components: %{"minecraft:max_stack_size" => 64}}
      })

    {:ok, items} = Items.restore({0, 0}, [a, b])
    assert {:ok, next, _} = ItemMerges.plan(items, items.epoch, [pair(items, 1, 2)])
    assert [saved] = Items.records(next)
    assert saved.stack == %{b.stack | count: 4} and saved.uuid == b.uuid
  end

  test "merging retains an unrelated outgoing intent, incoming history and birth receipts" do
    {:ok, items} = Items.restore({0, 0}, [record(1, 2), record(2, 3), record(3, 4)])
    {:ok, {epoch, id, revision}} = Items.find(items, <<3::128>>)
    step = %{id: id, revision: revision, position: {128.5, 64.0, 8.5}, motion: %ItemMotionState{}}
    {:ok, items, transfer} = ItemHandoffs.depart(items, {0, 0}, epoch, {1, 0}, [step])
    incoming = %{{-1, 0} => %{sequence: 8, digest: :crypto.hash(:sha256, "prior")}}
    items = %{items | ledger: %{items.ledger | incoming: incoming}}
    receipts = %{<<123::128>> => %{sequence: 11, digest: :crypto.hash(:sha256, "birth")}}
    assert {:ok, merged, _} = ItemMerges.plan(items, epoch, [pair(items, 1, 2)])
    assert {:ok, ^transfer} = ItemHandoffs.request(merged, {0, 0})
    assert merged.ledger.incoming == incoming

    assert {:ok, bytes} =
             ItemLedger.encode({0, 0}, Items.records(merged), receipts, merged.ledger)

    assert {:ok, %{receipts: ^receipts, ledger: ledger}} = ItemLedger.decode(bytes, {0, 0})
    assert ledger == merged.ledger
  end

  test "custom99 uses the native64 entity cap, including a recipient initially above64" do
    for {ac, bc, expected_recipient, expected_donor} <- [{32, 33, 64, 1}, {2, 65, 64, 3}] do
      custom = fn n ->
        %{ItemStack.new("stone", n) | components: %{"minecraft:max_stack_size" => 99}}
      end

      {:ok, items} =
        Items.restore({0, 0}, [
          record(1, ac, %{stack: custom.(ac)}),
          record(2, bc, %{stack: custom.(bc)})
        ])

      assert {:ok, next, [_]} = ItemMerges.plan(items, items.epoch, [pair(items, 1, 2)])

      assert Enum.map(Items.records(next), & &1.stack.count) == [
               expected_donor,
               expected_recipient
             ]

      assert Enum.sum(Enum.map(Items.records(next), & &1.stack.count)) == ac + bc
    end
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

  test "sentinels, removed entities and different pickup targets refuse; delayed entities can merge" do
    input = %{
      stack: ItemStack.new("stone", 2),
      motion: %ItemMotionState{},
      target: nil,
      alive: true
    }

    for change <- [%{age: -32768}, %{age: 6000}, %{pickup_delay: 32767}] do
      assert {:error, :not_mergeable} =
               ItemMerge.pair(%{input | motion: struct(input.motion, change)}, input)
    end

    assert {:error, :not_mergeable} = ItemMerge.pair(%{input | alive: false}, input)
    assert {:error, :not_mergeable} = ItemMerge.pair(%{input | target: <<1::128>>}, input)

    assert {:ok, %{motion: %{pickup_delay: 40}}} =
             ItemMerge.pair(%{input | motion: %{input.motion | pickup_delay: 40}}, input)
  end
end
