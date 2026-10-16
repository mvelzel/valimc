defmodule Valimc.PickupTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.{Inventory, ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{ItemLedger, ItemTransfers, Items, PickupRequest, PickupTransfers}

  defp scene(motion \\ %ItemMotionState{}) do
    record = %{
      uuid: <<71::128>>,
      x: 8.5,
      y: 64.0,
      z: 8.5,
      stack: ItemStack.new("stone", 7),
      motion: motion
    }

    {:ok, items} = Items.restore({0, 0}, [record], %ItemLedger{generations: %{record.uuid => 3}})

    request = %{
      source: <<1::128>>,
      sequence: 4,
      permit: <<13::128>>,
      item_uuid: record.uuid,
      generation: 3,
      before: record.stack,
      remainder: nil
    }

    {items, request, record}
  end

  defp recovered(items, receipts) do
    {:ok, bytes} = ItemLedger.encode({0, 0}, Items.records(items), receipts, items.ledger)
    {:ok, disk} = ItemLedger.decode(bytes, {0, 0})
    {:ok, items} = Items.restore({0, 0}, disk.records, disk.ledger)
    {items, disk.receipts}
  end

  test "canonical request pins exact partial stacks, source, permit, generation and destination" do
    {_, request, _} = scene()
    request = %{request | remainder: %{request.before | count: 3}}
    assert {:ok, bytes} = PickupRequest.encode({0, 0}, request)
    assert {:ok, ^request} = PickupRequest.decode(bytes, {0, 0})
    assert {:ok, digest} = PickupRequest.digest({0, 0}, request)
    assert byte_size(digest) == 32

    for changed <- [
          %{request | source: <<2::128>>},
          %{request | sequence: 5},
          %{request | permit: <<14::128>>},
          %{request | generation: 4},
          %{request | remainder: nil}
        ] do
      assert {:ok, other} = PickupRequest.digest({0, 0}, changed)
      assert other != digest
    end

    assert {:ok, other} = PickupRequest.digest({1, 0}, request)
    assert other != digest

    for length <- 0..(byte_size(bytes) - 1),
        do:
          assert(
            {:error, :invalid_pickup_request} ==
              PickupRequest.decode(binary_part(bytes, 0, length), {0, 0})
          )

    assert {:error, :invalid_pickup_request} = PickupRequest.decode(bytes <> <<0>>, {0, 0})
    assert {:error, :invalid_pickup_request} = PickupRequest.decode(bytes, {1, 0})

    for invalid <- [
          %{request | sequence: 0},
          %{request | generation: -1},
          %{request | source: <<1>>},
          %{request | remainder: request.before},
          %{request | remainder: ItemStack.new("egg")},
          Map.put(request, :ignored, true)
        ] do
      assert {:error, :invalid_pickup_request} = PickupRequest.encode({0, 0}, invalid)
    end
  end

  test "withdrawal and typed receipt replay never resurrect an item or lose its birth history" do
    {items, request, record} = scene()
    birth = %{source: request.source, sequence: 3, records: [record]}
    {:ok, birth_digest} = ItemTransfers.digest({0, 0}, birth)

    receipts = %{
      request.source => %{sequence: 3, digest: birth_digest},
      <<9::128>> => %{sequence: 8, digest: <<99::256>>}
    }

    assert {:ok, %{result: :applied} = plan} =
             PickupTransfers.plan(items, receipts, {0, 0}, request, true)

    assert Items.records(plan.items) == [] and plan.items.ledger.generations == %{}
    assert plan.receipts[<<9::128>>] == receipts[<<9::128>>]

    assert {:ok, :applied} =
             PickupTransfers.receipt_result({0, 0}, request, plan.receipts[request.source])

    {restored, receipts} = recovered(plan.items, plan.receipts)

    assert {:ok, %{items: ^restored, receipts: ^receipts, result: :already_applied}} =
             PickupTransfers.plan(restored, receipts, {0, 0}, request, false)

    assert {:error, :stale_transfer} = ItemTransfers.plan(restored, receipts, {0, 0}, birth)
  end

  test "partial insertion withdraws the exact remainder despite a false native pickup callback" do
    {items, request, record} = scene()

    full =
      Map.new(9..44, &{&1, ItemStack.new("stone", 64)}) |> Map.put(36, ItemStack.new("stone", 63))

    inventory = %Inventory{slots: full}
    assert {:ok, next, remainder, false} = Inventory.pickup_stack(inventory, record.stack)
    assert remainder.count == 6 and next.slots[36].count == 64
    request = %{request | remainder: remainder}

    assert {:ok, %{result: :applied} = plan} =
             PickupTransfers.plan(items, %{}, {0, 0}, request, true)

    assert [saved] = Items.records(plan.items)
    assert saved == %{record | stack: remainder}
    assert plan.items.ledger == items.ledger

    assert {:ok, :applied} =
             PickupTransfers.receipt_result({0, 0}, request, plan.receipts[request.source])
  end

  test "two player intents race to one withdrawal; rejection is terminal and replayable" do
    {items, a, _} = scene()
    b = %{a | source: <<2::128>>}
    assert {:ok, first} = PickupTransfers.plan(items, %{}, {0, 0}, a, true)

    assert {:ok, %{result: :rejected, items: unchanged} = second} =
             PickupTransfers.plan(first.items, first.receipts, {0, 0}, b, true)

    assert unchanged == first.items
    {items, receipts} = recovered(second.items, second.receipts)

    assert {:ok, %{items: ^items, receipts: ^receipts, result: :already_rejected}} =
             PickupTransfers.plan(items, receipts, {0, 0}, b, true)

    assert {:ok, :rejected} = PickupTransfers.receipt_result({0, 0}, b, receipts[b.source])

    assert {:error, :transfer_conflict} =
             PickupTransfers.plan(items, receipts, {0, 0}, %{a | permit: <<55::128>>}, true)

    assert {:error, :stale_transfer} =
             PickupTransfers.plan(items, receipts, {0, 0}, %{a | sequence: 3}, true)
  end

  test "invalid eligibility, changed stack/generation, delay and wrong region commit only rejection" do
    {items, request, _} = scene()

    for {key, changed, eligible} <- [
          {{0, 0}, request, false},
          {{0, 0}, %{request | generation: 2}, true},
          {{0, 0}, %{request | before: ItemStack.new("stone", 6)}, true},
          {{1, 0}, request, true}
        ] do
      assert {:ok, %{items: ^items, result: :rejected} = plan} =
               PickupTransfers.plan(items, %{}, key, changed, eligible)

      assert {:ok, :rejected} =
               PickupTransfers.receipt_result(key, changed, plan.receipts[changed.source])
    end

    {delayed, request, _} = scene(%ItemMotionState{pickup_delay: 1})

    assert {:ok, %{items: ^delayed, result: :rejected}} =
             PickupTransfers.plan(delayed, %{}, {0, 0}, request, true)
  end

  test "receipt capacity refuses new players but still acknowledges committed retries" do
    {items, request, _} = scene()
    receipts = Map.new(1..4096, &{<<&1::128>>, %{sequence: 1, digest: <<0::256>>}})
    unknown = %{request | source: <<5000::128>>}

    assert {:error, :transfer_source_limit} =
             PickupTransfers.plan(items, receipts, {0, 0}, unknown, true)

    assert {:ok, plan} = PickupTransfers.plan(items, receipts, {0, 0}, request, true)

    assert {:ok, %{result: :already_applied}} =
             PickupTransfers.plan(plan.items, plan.receipts, {0, 0}, request, false)

    assert {:error, :transfer_conflict} =
             PickupTransfers.receipt_result({0, 0}, request, %{sequence: 4, digest: <<0::256>>})
  end
end
