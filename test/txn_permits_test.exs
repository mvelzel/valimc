defmodule Valimc.TxnPermitsTest do
  use ExUnit.Case, async: true
  # Contact permits live the play lifetime here (VMC-073).
  setup do: Valimc.TestScope.isolate(self(), owner_call_scale: 1)
  alias Valimc.{GameMode, ItemMotionState, Txn.Permits}
  alias Valimc.Physics.{ItemPickup, PlayerPose}
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{
    ContainerPermits,
    ItemLedger,
    ItemMergePermits,
    Items,
    MiningPermits,
    PickupPermits,
    PickupRequest
  }

  # {kind, limit, one permit per source?}
  @kinds [
    {:pickup, 128, true},
    {:container, 128, true},
    {:item_merge, 8, true},
    {:mining, 128, false},
    {:placement, 128, false}
  ]

  defp issue(permits, kind, source, now, position \\ {0, 64, 0}),
    do: Permits.issue(permits, kind, nil, source, [position], %{kind: kind}, now)

  test "every kind expires strictly, is single use and cannot be taken by another source" do
    for {kind, _, _} <- @kinds do
      lifetime = Permits.lifetime(kind)
      {:ok, permits, token} = issue(Permits.new(), kind, <<1::128>>, 0)
      assert {:ok, %{kind: ^kind}} = Permits.lookup(permits, kind, token, lifetime - 1)
      assert :error = Permits.lookup(permits, kind, token, lifetime)
      assert :error = Permits.lookup(permits, :generation, token, 0)
      assert {^permits, nil} = Permits.take(permits, kind, token, <<2::128>>, 1)
      assert {empty, %{kind: ^kind}} = Permits.take(permits, kind, token, <<1::128>>, 1)
      assert {^empty, nil} = Permits.take(empty, kind, token, <<1::128>>, 1)

      assert {%Permits{entries: %{}}, nil} =
               Permits.take(permits, kind, token, <<1::128>>, lifetime)
    end
  end

  test "every kind bounds live grants; expiry and release reclaim them" do
    for {kind, limit, per_source} <- @kinds do
      full =
        Enum.reduce(1..limit, Permits.new(), fn n, permits ->
          {:ok, next, _} = issue(permits, kind, <<n::128>>, 0)
          next
        end)

      assert {:error, _full} = issue(full, kind, <<0::128>>, 1)
      {token, _} = Enum.find(full.entries, fn {_, e} -> e.source == <<1::128>> end)
      assert Permits.release(full, token, <<2::128>>) == full
      assert {:ok, _, _} = issue(Permits.release(full, token, <<1::128>>), kind, <<0::128>>, 1)
      assert {:ok, renewed, _} = issue(full, kind, <<0::128>>, Permits.lifetime(kind))
      assert map_size(renewed.entries) == 1

      {:ok, one, _} = issue(Permits.new(), kind, <<1::128>>, 0)

      if per_source,
        do: assert({:error, _pending} = issue(one, kind, <<1::128>>, 1)),
        else: assert({:ok, _, _} = issue(one, kind, <<1::128>>, 1))
    end
  end

  test "edits revoke bound positions; renewal keeps the grant and never revives a token" do
    blocks = %{{0, 63, 0} => 1}
    {:ok, permits, token} = MiningPermits.reserve(Permits.new(), blocks, 0)
    assert Permits.invalidate(permits, %{{1, 63, 0} => 1}) == permits
    assert Permits.invalidate(permits, blocks, [:mining]) == permits

    assert {:error, :stale_mining_permit} =
             MiningPermits.lookup(Permits.invalidate(permits, blocks), token, 1)

    {:ok, renewed, ^blocks} = MiningPermits.renew(permits, token, 9999)
    assert {:ok, ^blocks} = MiningPermits.lookup(renewed, token, 19_998)
    assert {:error, :stale_mining_permit} = MiningPermits.renew(renewed, token, 19_999)
    assert {:error, :stale_mining_permit} = MiningPermits.renew(permits, token, 10_000)
    released = Permits.release(renewed, token)
    assert {:error, :stale_mining_permit} = MiningPermits.renew(released, token, 10_001)
  end

  defp container do
    source = <<1::128>>
    {:ok, receipts, _} = Valimc.Txn.Receipts.reserve(%{}, source)

    {receipts, %{source: source, sequence: 7, permit: <<2::128>>, position: {0, 64, 0}},
     <<3::256>>}
  end

  test "container grants need a durable receipt slot and bind the exact request digest" do
    {receipts, request, digest} = container()

    for {receipts, request, digest} <- [
          {%{}, request, digest},
          {Map.put(receipts, request.source, %{sequence: 7, digest: <<0::256>>}), request,
           digest},
          {receipts, %{request | sequence: -1}, digest},
          {receipts, request, <<1>>}
        ] do
      assert {:error, :invalid_container_permit} =
               ContainerPermits.issue(Permits.new(), receipts, request, digest, 0)
    end

    {:ok, permits} = ContainerPermits.issue(Permits.new(), receipts, request, digest, 0)
    {_, grant} = ContainerPermits.take(permits, request, 1)
    assert ContainerPermits.eligible?(grant, request, digest)

    # A changed payload or sequence still burns its token.
    for {changed, changed_digest} <- [{request, <<9::256>>}, {%{request | sequence: 8}, digest}] do
      {%Permits{entries: entries}, grant} = ContainerPermits.take(permits, changed, 1)
      assert entries == %{}
      refute ContainerPermits.eligible?(grant, changed, changed_digest)
    end
  end

  defp pickup do
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
    {:ok, receipts, :reserved} = Valimc.Txn.Receipts.reserve(%{}, actor.uuid)
    {actor, record, items, receipts}
  end

  test "pickup grants need a receipt slot and fresh range, stack, delay and generation" do
    {actor, record, items, receipts} = pickup()

    assert {:error, :pickup_receipt_slot_required} =
             PickupPermits.issue(Permits.new(), %{}, items, actor, record.uuid, 1000)

    {:ok, permits, grant} =
      PickupPermits.issue(Permits.new(), receipts, items, actor, record.uuid, 1000)

    request = Map.merge(grant, %{source: actor.uuid, sequence: 1, remainder: nil})
    {:ok, _} = PickupRequest.encode({0, 0}, request)
    {aged, []} = Items.age(items)
    assert {_, _, true} = PickupPermits.consume(permits, aged, request, 1249)
    {:ok, {epoch, id, revision}} = Items.find(items, record.uuid)

    {:ok, moved, _} =
      Items.advance(items, {0, 0}, epoch, [
        %{id: id, revision: revision, position: {20.0, 64.0, 8.5}, motion: %ItemMotionState{}}
      ])

    {:ok, delayed, _} =
      Items.advance(items, {0, 0}, epoch, [
        %{
          id: id,
          revision: revision,
          position: {9.0, 64.0, 8.5},
          motion: %ItemMotionState{pickup_delay: 40}
        }
      ])

    {:ok, changed, _} = Items.replace(items, epoch, id, revision, ItemStack.new("stone", 6))
    {:ok, removed} = Items.remove(items, epoch, id, revision)
    returned = %{items | ledger: %{items.ledger | generations: %{record.uuid => 5}}}

    for current <- [moved, delayed, changed, removed, returned] do
      assert {%Permits{entries: %{}}, _, false} =
               PickupPermits.consume(permits, current, request, 1100)
    end

    for forged <- [%{request | before: ItemStack.new("stone", 6)}, %{request | generation: 4}] do
      assert {_, _, false} = PickupPermits.consume(permits, items, forged, 1100)
    end

    entry = items.entries |> Map.values() |> hd()

    for changed <- [
          put_in(actor.health.value, 0.0),
          %{actor | game_mode: GameMode.new(:spectator)},
          Map.put(actor, :passenger, true)
        ] do
      refute ItemPickup.eligible?(changed, entry)
    end

    refute ItemPickup.eligible?(actor, Map.put(entry, :pickup_target, <<2::128>>))
  end

  defp merge do
    donor = %{
      uuid: <<1::128>>,
      x: 127.9,
      y: 64.0,
      z: 8.5,
      stack: ItemStack.new("stone", 2),
      motion: %ItemMotionState{age: 30}
    }

    recipient = %{donor | uuid: <<2::128>>, x: 128.1, stack: ItemStack.new("stone", 3)}

    {:ok, items} =
      Items.restore({1, 0}, [recipient], %ItemLedger{generations: %{recipient.uuid => 4}})

    proposal = %{
      source: {0, 0},
      sequence: 1,
      donor: donor,
      donor_generation: 2,
      recipient_uuid: recipient.uuid
    }

    {:ok, request} = ItemMergePermits.prepare(items, {1, 0}, proposal)
    {items, proposal, request, %{{0, 0} => %{sequence: 0, digest: <<0::256>>}}}
  end

  test "merge grants need committed receipt capacity, fence the pair and pick one direction" do
    {items, proposal, request, incoming} = merge()

    assert {:error, :item_merge_reservation_required} =
             ItemMergePermits.grant(Permits.new(), %{}, request, 1000)

    {:ok, permits, ^request} = ItemMergePermits.grant(Permits.new(), incoming, request, 1000)
    assert {_, true} = ItemMergePermits.consume(permits, items, request, 1100)

    for mutated <- [
          %{request | donor_generation: 3},
          %{request | donor: %{request.donor | x: 120.0}},
          %{request | recipient: %{request.recipient | uuid: <<3::128>>}}
        ] do
      assert {%Permits{entries: %{}}, false} =
               ItemMergePermits.consume(permits, items, mutated, 1100)
    end

    returned = %{items | ledger: %{items.ledger | generations: %{request.recipient.uuid => 6}}}
    assert {_, false} = ItemMergePermits.consume(permits, returned, request, 1100)

    # Equal counts merge toward the higher owner only, so withdrawals cannot oscillate.
    equal = %{proposal | donor: %{proposal.donor | stack: ItemStack.new("stone", 3)}}
    assert {:ok, _} = ItemMergePermits.prepare(items, {1, 0}, equal)
    target = %{equal.donor | uuid: <<4::128>>}
    {:ok, reverse} = Items.restore({0, 0}, [target])

    assert {:error, :item_merge_not_available} =
             ItemMergePermits.prepare(reverse, {0, 0}, %{
               equal
               | source: {1, 0},
                 donor: %{target | uuid: <<5::128>>, x: 128.1},
                 recipient_uuid: target.uuid
             })
  end
end
