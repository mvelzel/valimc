defmodule Valimc.PendingCookingAwardsTest do
  use ExUnit.Case, async: true
  alias Valimc.{Cooking, CookingAwards, Inventory}
  alias Valimc.Protocol.ItemStack
  alias Valimc.World.{ContainerRequest, Containers, ContainerTransfers, PendingCookingAwards}
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

  test "invalid context or ineligible admission records rejection without clearing credit" do
    {cs, req, context} = fixture()

    for {eligible, bad} <- [
          {false, context},
          {true, %{context | draws: %{}}},
          {true, %{context | position: {30_000_000, 64, 0}}},
          {true, %{}},
          {true, %{context | draws: %{@recipe => 16_777_216}}}
        ] do
      assert {:ok, %{result: :rejected, containers: next}} =
               ContainerTransfers.plan_cooking_award(cs, @key, req, eligible, bad)

      assert next.entries == cs.entries and next.pending_awards == %{}

      assert {:ok, %{result: :already_rejected}} =
               ContainerTransfers.plan_cooking_award(next, @key, req, true, context)
    end

    {:ok, bare, _} = Containers.create_cooking(%Containers{}, @key, @pos, :furnace)

    assert {:error, :missing_container_receipt_slot} =
             ContainerTransfers.plan_cooking_award(bare, @key, req, true, context)
  end

  test "zero-XP outcomes retain a recipe effect and integral outcomes store no draw" do
    {cs, req, context} = fixture()

    for {recipe, count, draws, amount} <- [
          {"minecraft:smooth_stone", 1, %{"minecraft:smooth_stone" => 16_777_215}, 0},
          {"minecraft:gold_ingot_from_smelting_gold_ore", 3, %{}, 3}
        ] do
      cs = put_in(cs.entries[@pos].recipes, %{recipe => count})
      next = applied(cs, req, %{context | draws: draws})
      [record] = Map.values(next.pending_awards)
      assert record.award.experience == amount
      assert record.award.recipes == [%{recipe: recipe, uses: count, experience: amount}]
      assert record.award.draws_used == draws
      assert {:ok, bytes} = Containers.encode(@key, next)
      assert {:ok, ^next} = Containers.decode(bytes, @key)
    end
  end

  test "ledger capacity rejects whole transfer and retains earlier awards" do
    {cs, req, context} = fixture()
    source = <<9::128>>
    {:ok, award} = CookingAwards.plan(%{@recipe => 7}, %{@recipe => 0})

    {awards, digest} =
      Enum.reduce(1..PendingCookingAwards.max_awards(), {%{}, nil}, fn n, {awards, _} ->
        digest = :crypto.hash(:sha256, <<n::32>>)

        {:ok, next, _} =
          PendingCookingAwards.put(awards, @key, source, n, digest, context.position, award)

        {next, digest}
      end)

    receipt = %{
      sequence: PendingCookingAwards.max_awards(),
      digest: ContainerTransfers.result_digest(digest, :applied)
    }

    cs = %{cs | pending_awards: awards, receipts: Map.put(cs.receipts, source, receipt)}
    assert {:ok, _} = Containers.encode(@key, cs)

    assert {:ok, %{result: :rejected, containers: next}} =
             ContainerTransfers.plan_cooking_award(cs, @key, req, true, context)

    assert next.entries == cs.entries and next.pending_awards == awards

    assert {:error, :cooking_award_limit} =
             PendingCookingAwards.put(
               awards,
               @key,
               @source,
               1,
               <<7::256>>,
               context.position,
               award
             )
  end

  test "canonical ledger decoding rejects wrong region, duplicated identity and forged decisions" do
    {cs, req, context} = fixture()
    next = applied(cs, req, context)
    assert {:ok, bytes} = PendingCookingAwards.encode(@key, next.pending_awards, next.receipts)
    assert {:ok, awards} = PendingCookingAwards.decode(bytes, @key, next.receipts)
    assert awards == next.pending_awards

    assert {:error, :invalid_pending_cooking_awards} =
             PendingCookingAwards.decode(bytes, {1, 0}, next.receipts)

    <<1::16, record::binary>> = bytes

    for damaged <- [
          <<>>,
          binary_part(bytes, 0, byte_size(bytes) - 1),
          bytes <> <<0>>,
          <<2::16, record::binary, record::binary>>,
          <<257::16>>,
          :binary.copy(<<0>>, PendingCookingAwards.max_bytes() + 1)
        ] do
      assert {:error, :invalid_pending_cooking_awards} =
               PendingCookingAwards.decode(damaged, @key, next.receipts)
    end

    <<prefix::binary-size(121), index::16, uses::32, amount::32, _::32, rest::binary>> = bytes
    forged = <<prefix::binary, index::16, uses::32, amount::32, 16_777_217::32, rest::binary>>

    assert {:error, :invalid_pending_cooking_awards} =
             PendingCookingAwards.decode(forged, @key, next.receipts)

    [{id, value}] = Map.to_list(awards)

    for wrong <- [
          put_in(value.award.experience, 99),
          %{value | position: {0, 64, 0}},
          put_in(value.award.draws_used, %{}),
          %{value | sequence: 0}
        ] do
      assert {:error, :invalid_pending_cooking_awards} =
               PendingCookingAwards.encode(@key, %{id => wrong}, next.receipts)
    end

    assert {:error, :cooking_award_conflict} =
             PendingCookingAwards.put(
               awards,
               @key,
               value.source,
               value.sequence,
               value.digest,
               {1, 64, 1},
               value.award
             )

    assert {:error, :cooking_award_conflict} =
             PendingCookingAwards.put(
               awards,
               @key,
               value.source,
               value.sequence,
               <<7::256>>,
               value.position,
               value.award
             )

    {:ok, alternate, _} =
      PendingCookingAwards.put(
        %{},
        @key,
        value.source,
        value.sequence,
        <<7::256>>,
        value.position,
        value.award
      )

    assert {:error, :invalid_pending_cooking_awards} =
             PendingCookingAwards.encode(@key, Map.merge(awards, alternate), next.receipts)

    assert {:ok, ^awards, ^id} =
             PendingCookingAwards.put(
               awards,
               @key,
               value.source,
               value.sequence,
               value.digest,
               value.position,
               value.award
             )
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
