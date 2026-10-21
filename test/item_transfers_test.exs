defmodule Valimc.ItemTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{Items, ItemTransfers}

  defp record(n),
    do: %{uuid: <<n::128>>, x: 0.5, y: 64.5, z: 0.5, stack: ItemStack.new("stone", 7)}

  defp request(sequence \\ 1, records \\ [record(1)]),
    do: %{source: <<90::128>>, sequence: sequence, records: records}

  test "canonical batches, exact retries, conflicts and monotonically fenced source sequences" do
    batch = request(1, [record(1), record(2)])
    assert {:ok, items, receipts, :applied} = ItemTransfers.plan(Items.new(), %{}, {0, 0}, batch)
    assert map_size(items.entries) == 2 and map_size(receipts) == 1

    assert {:ok, ^items, ^receipts, :already_applied} =
             ItemTransfers.plan(items, receipts, {0, 0}, %{
               batch
               | records: Enum.reverse(batch.records)
             })

    conflicting = %{batch | records: [%{record(1) | stack: ItemStack.new("stone", 8)}, record(2)]}
    assert {:error, :transfer_conflict} = ItemTransfers.plan(items, receipts, {0, 0}, conflicting)

    assert {:ok, next, newest, :applied} =
             ItemTransfers.plan(items, receipts, {0, 0}, request(100, [record(3)]))

    assert map_size(newest) == 1 and newest[batch.source].sequence == 100
    assert {:error, :stale_transfer} = ItemTransfers.plan(next, newest, {0, 0}, batch)
  end

  test "removal and live UUID collisions never turn a retry into another creation" do
    batch = request()
    {:ok, items, receipts, :applied} = ItemTransfers.plan(Items.new(), %{}, {0, 0}, batch)

    assert {:error, :duplicate_item_uuid} =
             ItemTransfers.plan(items, receipts, {0, 0}, %{batch | source: <<91::128>>})

    {:ok, {epoch, id, revision}} = Items.find(items, record(1).uuid)
    {:ok, empty} = Items.remove(items, epoch, id, revision)

    assert {:ok, ^empty, ^receipts, :already_applied} =
             ItemTransfers.plan(empty, receipts, {0, 0}, batch)

    assert empty.entries == %{}
  end
end
