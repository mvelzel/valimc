defmodule Valimc.PendingCookingAwardsTest do
  use ExUnit.Case, async: true
  alias Valimc.{Cooking, Inventory}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerRequest, Containers, ContainerTransfers}
  @recipe "minecraft:iron_ingot_from_smelting_raw_iron"
  @key {0, 0}
  @pos {0, 64, 0}
  @source <<1::128>>

  defp fixture do
    {:ok, cs, entry} = Containers.create_cooking(%Containers{}, @key, @pos, :furnace)
    cooking = %Cooking{slots: {nil, nil, ItemStack.new("iron_ingot", 4)}, total: 200}

    {:ok, cs, entry} =
      Containers.replace_cooking(cs, @pos, entry.revision, cooking, %{@recipe => 7})

    {:ok, cs, _} = ContainerTransfers.reserve(cs, @source)

    req = %{
      source: @source,
      sequence: 1,
      permit: <<4::128>>,
      position: @pos,
      revision: entry.revision,
      kind: :furnace,
      slots: cooking.slots,
      inventory: %Inventory{},
      action: :pickup,
      slot: 2,
      button: 1
    }

    {cs, req, %{position: {0.5, 64.0, -0.5}, draws: %{@recipe => 0}}}
  end

  defp applied(cs, req, context) do
    {:ok, %{result: :applied, containers: next}} =
      ContainerTransfers.plan_cooking_award(cs, @key, req, true, context)

    next
  end

  test "partial withdrawal binds all recipe credit and receipt into one immutable snapshot" do
    {cs, req, context} = fixture()

    assert {:ok, %{result: :rejected, containers: refused}} =
             ContainerTransfers.plan(cs, @key, req, true)

    assert refused.entries == cs.entries and refused.pending_awards == %{}
    next = applied(cs, req, context)
    assert next.entries[@pos].recipes == %{}
    assert elem(next.entries[@pos].cooking.slots, 2) == ItemStack.new("iron_ingot", 2)
    assert {:ok, _, player} = ContainerRequest.plan(req)
    assert player.carried == ItemStack.new("iron_ingot", 2)
    [{id, record}] = Map.to_list(next.pending_awards)
    assert byte_size(id) == 32

    assert record.source == @source and record.sequence == 1 and
             record.position == context.position

    assert record.award.experience == 5
    assert record.award.recipes == [%{recipe: @recipe, uses: 7, experience: 5}]
    assert record.award.draws_used == context.draws
    assert {:ok, digest} = ContainerRequest.digest(@key, req)
    assert record.digest == digest
    assert next.receipts[@source].digest == ContainerTransfers.result_digest(digest, :applied)
    assert {:ok, <<"VMCCONTS", 4, _::binary>> = bytes} = Containers.encode(@key, next)
    assert {:ok, ^next} = Containers.decode(bytes, @key)

    # An owner stores the spawn pose even across a neighboring region boundary.
    assert record.position == {0.5, 64.0, -0.5}
    assert {:ok, removed, _} = Containers.remove(next, @pos, next.entries[@pos].revision)
    assert removed.pending_awards == next.pending_awards
    assert {:ok, removed_bytes} = Containers.encode(@key, removed)
    assert {:ok, ^removed} = Containers.decode(removed_bytes, @key)
  end

  test "replay ignores new entropy/eligibility and conflicting or stale actions cannot mint credit" do
    {cs, req, context} = fixture()
    next = applied(cs, req, context)

    assert {:ok, %{result: :already_applied, containers: ^next}} =
             ContainerTransfers.plan_cooking_award(next, @key, req, false, :different_entropy)

    assert {:error, :transfer_conflict} =
             ContainerTransfers.plan_cooking_award(next, @key, %{req | button: 0}, true, context)

    entry = next.entries[@pos]
    noop = %{req | sequence: 2, revision: entry.revision, slots: entry.cooking.slots, slot: 0}

    assert {:ok, %{result: :applied, containers: later}} =
             ContainerTransfers.plan(next, @key, noop, true)

    assert later.pending_awards == next.pending_awards
    assert {:ok, bytes} = Containers.encode(@key, later)
    assert {:ok, ^later} = Containers.decode(bytes, @key)

    assert {:error, :stale_transfer} =
             ContainerTransfers.plan_cooking_award(later, @key, req, true, context)

    for changed <- [
          %{next | receipts: %{}},
          %{next | receipts: cs.receipts},
          %{next | receipts: %{@source => %{sequence: 1, digest: <<0::256>>}}}
        ] do
      assert {:error, :invalid_container_snapshot} = Containers.encode(@key, changed)
    end
  end

  test "competing old views cannot award the same credit twice, and the remainder earns no new credit" do
    {cs, req, context} = fixture()
    other = <<2::128>>
    {:ok, cs, _} = ContainerTransfers.reserve(cs, other)
    second = %{req | source: other}
    first = applied(cs, req, context)

    assert {:ok, %{result: :rejected, containers: rejected}} =
             ContainerTransfers.plan_cooking_award(first, @key, second, true, context)

    assert rejected.entries == first.entries and rejected.pending_awards == first.pending_awards

    entry = first.entries[@pos]

    refreshed = %{
      second
      | sequence: 2,
        revision: entry.revision,
        slots: entry.cooking.slots,
        button: 0
    }

    assert {:ok, %{result: :applied, containers: remaining}} =
             ContainerTransfers.plan(rejected, @key, refreshed, true)

    assert elem(remaining.entries[@pos].cooking.slots, 2) == nil
    assert remaining.pending_awards == first.pending_awards
    assert {:ok, _, a} = ContainerRequest.plan(req)
    assert {:ok, _, b} = ContainerRequest.plan(refreshed)
    assert a.carried.count + b.carried.count == 4
    assert {:ok, bytes} = Containers.encode(@key, remaining)
    assert {:ok, ^remaining} = Containers.decode(bytes, @key)
  end

  test "legacy versions keep exact bytes and never invent pending awards" do
    {:ok, chest, _} = Containers.create(%Containers{}, @key, @pos, 3)
    {:ok, typed, _} = ContainerTransfers.reserve(chest, @source)
    {cooking, _, _} = fixture()

    # Original d4e5e59 encoder hashes, retained before the v4 extension.
    for {version, state, hash} <- [
          {1, chest, "3b92014792c633cb7f7f1feb969c43933dd55e094b87fab5ddad9d618ac905e2"},
          {2, typed, "ac67ffa682d7e130f444210f959bd7ac02ae2726fd7e28b735db4289430171e7"},
          {3, cooking, "cd0de3321bf9c0efbc6582a033cb061e93abf918e71615b1770d33a5da57d1f2"}
        ] do
      assert {:ok, <<"VMCCONTS", ^version, _::binary>> = bytes} = Containers.encode(@key, state)
      assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) == hash
      assert {:ok, decoded} = Containers.decode(bytes, @key)
      assert decoded == state and decoded.pending_awards == %{}
      assert {:ok, ^bytes} = Containers.encode(@key, decoded)
    end
  end
end
