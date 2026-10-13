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

  test "invalid, oversized and partially over-capacity batches cannot publish a partial plan" do
    initial = Items.new()

    for bad <- [
          %{request() | source: <<0>>},
          %{request() | sequence: 0},
          %{request() | sequence: 18_446_744_073_709_551_616},
          request(1, []),
          request(1, Enum.map(1..6, &record/1)),
          request(1, [record(1), record(1)]),
          request(1, [%{record(1) | x: -0.5}]),
          request(1, [%{record(1) | stack: nil}]),
          request(1, [%{record(1) | stack: ItemStack.new("egg", 17)}]),
          request(1, [:bad])
        ] do
      assert {:error, :invalid_transfer} = ItemTransfers.plan(initial, %{}, {0, 0}, bad)
    end

    {:ok, full} = Items.restore({0, 0}, Enum.map(1..255, &record/1))

    assert {:error, :item_count_limit} =
             ItemTransfers.plan(full, %{}, {0, 0}, request(1, [record(256), record(257)]))

    assert map_size(full.entries) == 255

    big = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"big" => {:byte_array, :binary.copy(<<1>>, 60_000)}}}
        }
    }

    records = for n <- 1..8, do: %{record(n) | stack: big}
    {:ok, dense} = Items.restore({0, 0}, records)

    assert {:error, :item_byte_limit} =
             ItemTransfers.plan(dense, %{}, {0, 0}, request(1, [%{record(9) | stack: big}]))

    assert map_size(dense.entries) == 8
  end

  test "source history is bounded and an existing source can advance at capacity" do
    receipt = %{sequence: 1, digest: <<0::256>>}
    all = Map.new(1..4096, &{<<&1::128>>, receipt})

    assert {:error, :transfer_source_limit} =
             ItemTransfers.plan(Items.new(), all, {0, 0}, %{request() | source: <<4097::128>>})

    assert {:ok, _, next, :applied} =
             ItemTransfers.plan(Items.new(), all, {0, 0}, %{request(2) | source: <<1::128>>})

    assert map_size(next) == 4096 and next[<<1::128>>].sequence == 2
  end
end
