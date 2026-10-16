defmodule Valimc.PickupPermitsTest do
  use ExUnit.Case, async: true
  alias Valimc.{GameMode, ItemMotionState}
  alias Valimc.Physics.{ItemPickup, PlayerPose}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ItemLedger, ItemReceipts, Items, PickupPermits, PickupRequest}

  defp fixture do
    {:ok, body} = PlayerPose.geometry(:standing, {8.5, 64.0, 8.5})

    actor = %{
      uuid: <<1::128>>,
      box: body.box,
      game_mode: GameMode.new(:survival),
      health: %{value: 20.0}
    }

    record = %{
      uuid: <<77::128>>,
      x: 9.0,
      y: 64.0,
      z: 8.5,
      stack: ItemStack.new("stone", 7),
      motion: %ItemMotionState{}
    }

    {:ok, items} = Items.restore({0, 0}, [record], %ItemLedger{generations: %{record.uuid => 3}})
    {:ok, receipts, :reserved} = ItemReceipts.reserve(%{}, actor.uuid)
    {actor, record, items, receipts}
  end

  defp issue do
    {actor, record, items, receipts} = fixture()

    {:ok, permits, grant} =
      PickupPermits.issue(PickupPermits.new(), receipts, items, actor, record.uuid, 1000)

    request = Map.merge(grant, %{source: actor.uuid, sequence: 1, remainder: nil})
    {:ok, _} = PickupRequest.encode({0, 0}, request)
    {actor, record, items, receipts, permits, request}
  end

  test "grant requires receipt capacity, expires strictly and is single use despite counter revisions" do
    {actor, record, items, receipts} = fixture()

    assert {:error, :pickup_receipt_slot_required} =
             PickupPermits.issue(PickupPermits.new(), %{}, items, actor, record.uuid, 1000)

    {_, _, _, _, permits, request} = issue()
    assert byte_size(request.permit) == 16
    {aged, []} = Items.age(items)
    assert {empty, true} = PickupPermits.consume(permits, aged, request, 1249)
    assert empty.entries == %{}
    assert {^empty, false} = PickupPermits.consume(empty, aged, request, 1249)
    assert {expired, false} = PickupPermits.consume(permits, items, request, 1250)
    assert expired.entries == %{}

    assert {:error, :pickup_already_pending} =
             PickupPermits.issue(permits, receipts, items, actor, record.uuid, 1100)
  end

  test "fresh range, stack, pickup delay and ownership generation invalidate old grants" do
    {_, _, items, _, permits, request} = issue()
    {:ok, {epoch, id, revision}} = Items.find(items, request.item_uuid)

    {:ok, moved, _} =
      Items.advance(items, {0, 0}, epoch, [
        %{id: id, revision: revision, position: {20.0, 64.0, 8.5}, motion: %ItemMotionState{}}
      ])

    {:ok, changed, _} = Items.replace(items, epoch, id, revision, ItemStack.new("stone", 6))

    {:ok, delayed, _} =
      Items.advance(items, {0, 0}, epoch, [
        %{
          id: id,
          revision: revision,
          position: {9.0, 64.0, 8.5},
          motion: %ItemMotionState{pickup_delay: 40}
        }
      ])

    returned = %{items | ledger: %{items.ledger | generations: %{request.item_uuid => 5}}}
    {:ok, removed} = Items.remove(items, epoch, id, revision)

    for current <- [moved, changed, delayed, returned, removed] do
      assert {consumed, false} = PickupPermits.consume(permits, current, request, 1100)
      assert consumed.entries == %{}
    end
  end

  test "another source cannot consume a grant; mutated request cannot authorize withdrawal" do
    {_, _, items, _, permits, request} = issue()

    assert {^permits, false} =
             PickupPermits.consume(permits, items, %{request | source: <<2::128>>}, 1100)

    for changed <- [
          %{request | before: ItemStack.new("stone", 6)},
          %{request | generation: 4},
          %{request | item_uuid: <<3::128>>}
        ] do
      assert {consumed, false} = PickupPermits.consume(permits, items, changed, 1100)
      assert consumed.entries == %{}
    end
  end

  test "bounded admission rejects overload and expires transient grants without deleting receipt slots" do
    {actor, record, items, _} = fixture()
    receipts = Map.new(1..129, &{<<&1::128>>, %{sequence: 0, digest: <<0::256>>}})

    permits =
      Enum.reduce(1..128, PickupPermits.new(), fn n, perms ->
        {:ok, next, _} =
          PickupPermits.issue(
            perms,
            receipts,
            items,
            %{actor | uuid: <<n::128>>},
            record.uuid,
            1000
          )

        next
      end)

    assert map_size(permits.entries) == 128

    assert {:error, :pickup_permits_full} =
             PickupPermits.issue(
               permits,
               receipts,
               items,
               %{actor | uuid: <<129::128>>},
               record.uuid,
               1100
             )

    assert {:ok, expired, _} =
             PickupPermits.issue(
               permits,
               receipts,
               items,
               %{actor | uuid: <<129::128>>},
               record.uuid,
               1250
             )

    assert map_size(expired.entries) == 1 and map_size(receipts) == 129
  end

  test "dead, spectator, mounted, targeted and out-of-contact actors refuse" do
    {actor, _, items, _} = fixture()
    entry = items.entries |> Map.values() |> hd()
    assert ItemPickup.eligible?(actor, entry)

    for changed <- [
          put_in(actor.health.value, 0.0),
          %{actor | game_mode: GameMode.new(:spectator)},
          Map.put(actor, :passenger, true),
          %{actor | box: {20.0, 64.0, 20.0, 20.6, 65.8, 20.6}}
        ] do
      refute ItemPickup.eligible?(changed, entry)
    end

    refute ItemPickup.eligible?(actor, Map.put(entry, :pickup_target, <<2::128>>))
    assert ItemPickup.eligible?(actor, Map.put(entry, :pickup_target, actor.uuid))
    refute ItemPickup.contact?({0, 0, 0, 1, 1, 1}, {:invalid, 0, 0})
  end
end
