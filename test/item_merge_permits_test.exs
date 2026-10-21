defmodule Valimc.ItemMergePermitsTest do
  use ExUnit.Case, async: true
  # Item merge permits live the play lifetime here (VMC-073).
  setup do: Valimc.TestScope.isolate(self(), owner_call_scale: 1)
  alias Valimc.{ItemMotionState, Protocol.ItemStack}
  alias Valimc.World.{ItemLedger, ItemMergePermits, Items}

  defp fixture do
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
    incoming = %{{0, 0} => %{sequence: 0, digest: <<0::256>>}}
    {items, proposal, request, incoming}
  end

  test "only committed receipt capacity grants a single-use contact with strict expiry" do
    {items, _, request, incoming} = fixture()

    assert {:error, :item_merge_reservation_required} =
             ItemMergePermits.grant(Valimc.Txn.Permits.new(), %{}, request, 1000)

    assert {:ok, permits, ^request} =
             ItemMergePermits.grant(Valimc.Txn.Permits.new(), incoming, request, 1000)

    assert {:error, :item_merge_already_pending} =
             ItemMergePermits.available?(permits, {0, 0}, 1100)

    {aged, []} = Items.age(items)

    refreshed = %{
      request
      | donor: %{request.donor | x: 127.95, motion: %ItemMotionState{age: 31}}
    }

    assert {empty, true} = ItemMergePermits.consume(permits, aged, refreshed, 1249)
    assert empty.entries == %{}
    assert {^empty, false} = ItemMergePermits.consume(empty, aged, refreshed, 1249)
    assert {expired, false} = ItemMergePermits.consume(permits, items, request, 1250)
    assert expired.entries == %{}
  end

  test "other owners cannot burn a grant; source identity and recipient state remain fenced" do
    {items, _, request, incoming} = fixture()
    {:ok, permits, _} = ItemMergePermits.grant(Valimc.Txn.Permits.new(), incoming, request, 1000)

    assert {^permits, false} =
             ItemMergePermits.consume(permits, items, %{request | source: {0, -1}}, 1100)

    assert Valimc.Txn.Permits.release(permits, request.permit, {0, -1}) == permits
    assert Valimc.Txn.Permits.release(permits, request.permit, {0, 0}).entries == %{}

    for mutated <- [
          %{request | sequence: 2},
          %{request | donor_generation: 3},
          %{request | donor: %{request.donor | stack: ItemStack.new("stone")}},
          %{request | donor: %{request.donor | x: 120.0}},
          %{request | recipient: %{request.recipient | uuid: <<3::128>>}}
        ] do
      assert {consumed, false} = ItemMergePermits.consume(permits, items, mutated, 1100)
      assert consumed.entries == %{}
    end

    returned = %{items | ledger: %{items.ledger | generations: %{request.recipient.uuid => 6}}}
    assert {_, false} = ItemMergePermits.consume(permits, returned, request, 1100)
  end

  test "equal-count pairs choose one donor owner so opposing withdrawals cannot oscillate" do
    {items, proposal, _, _} = fixture()
    equal = %{proposal | donor: %{proposal.donor | stack: ItemStack.new("stone", 3)}}
    assert {:ok, _} = ItemMergePermits.prepare(items, {1, 0}, equal)
    reverse_target = %{equal.donor | uuid: <<4::128>>, stack: ItemStack.new("stone", 3)}
    {:ok, reverse} = Items.restore({0, 0}, [reverse_target])

    reverse_proposal = %{
      equal
      | source: {1, 0},
        donor: %{reverse_target | uuid: <<5::128>>, x: 128.1},
        recipient_uuid: reverse_target.uuid
    }

    assert {:error, :item_merge_not_available} =
             ItemMergePermits.prepare(reverse, {0, 0}, reverse_proposal)
  end
end
