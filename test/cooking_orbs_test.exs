defmodule Valimc.CookingOrbsTest do
  use ExUnit.Case, async: true
  alias Valimc.CookingAwards
  alias Valimc.World.{Containers, ContainerTransfers, CookingOrbs, PendingCookingAwards}
  @gold "minecraft:gold_ingot_from_smelting_gold_ore"
  @iron "minecraft:iron_ingot_from_smelting_raw_iron"
  @key {0, 0}
  @source <<1::128>>
  @position {0.5, 64.25, 0.5}

  defp award(
         state \\ %Containers{},
         uses \\ %{@gold => 3, @iron => 5},
         draws \\ %{@iron => 0},
         position \\ @position
       ) do
    sequence = map_size(state.pending_awards) + 1
    digest = :crypto.hash(:sha256, <<sequence::32>>)
    {:ok, decision} = CookingAwards.plan(uses, draws)

    {:ok, awards, id} =
      PendingCookingAwards.put(
        state.pending_awards,
        @key,
        @source,
        sequence,
        digest,
        position,
        decision
      )

    receipt = %{sequence: sequence, digest: ContainerTransfers.result_digest(digest, :applied)}
    {%{state | pending_awards: awards, receipts: %{@source => receipt}}, id}
  end

  defp balance(cs) do
    pending =
      for {id, r} <- cs.pending_awards,
          not Map.has_key?(cs.cooking_orbs, id),
          do: r.award.experience

    materialized = for {_, orbs} <- cs.cooking_orbs, {_, r} <- orbs, do: r.value * r.count
    {Enum.sum(pending), Enum.sum(materialized)}
  end

  defp rehash(bytes) do
    payload = binary_part(bytes, 0, byte_size(bytes) - 32)
    payload <> :crypto.hash(:sha256, payload)
  end

  test "native denominations are bounded independently of the number of XP units" do
    assert {:ok, %{}} = CookingOrbs.split(0)
    assert {:ok, %{3 => 2}} = CookingOrbs.split(6)
    assert {:ok, %{7 => 1}} = CookingOrbs.split(7)

    for amount <- [1, 2, 3, 7, 73, 2476, 2477, 4925, 1_000_000, 2_147_483_647] do
      assert {:ok, groups} = CookingOrbs.split(amount)
      assert map_size(groups) <= 11
      assert Enum.sum(Enum.map(groups, fn {v, n} -> v * n end)) == amount
    end

    for amount <- [-1, 2_147_483_648, 1.0, nil, %{}] do
      assert {:error, :invalid_experience} = CookingOrbs.split(amount)
    end
  end

  test "one atomic successor preserves per-recipe splitting, recipes, receipts and stable UUIDs" do
    {before, id} = award()
    assert balance(before) == {7, 0}
    assert {:ok, next, :materialized} = CookingOrbs.materialize(before, @key, id)
    assert balance(next) == {0, 7}
    assert next.pending_awards === before.pending_awards
    assert next.receipts === before.receipts
    assert next.entries === before.entries and next.sequence == before.sequence

    assert Enum.sort(Enum.map(next.cooking_orbs[id], fn {_, r} -> {r.value, r.count} end)) == [
             {1, 1},
             {3, 2}
           ]

    assert Enum.all?(next.cooking_orbs[id], fn {<<_::48, 8::4, _::12, 2::2, _::62>>, r} ->
             r.position === @position
           end)

    assert {:ok, bytes} = Containers.encode(@key, next)
    assert <<"VMCCONTS", 5, _::binary>> = bytes
    assert {:ok, restored} = Containers.decode(bytes, @key)
    assert restored === next
    assert {:ok, ^bytes} = Containers.encode(@key, restored)
    assert {:ok, ^next, :already_materialized} = CookingOrbs.materialize(restored, @key, id)
    assert {:ok, ^next, :materialized} = CookingOrbs.materialize(before, @key, id)

    {later, second} = award(next)
    assert {:ok, final, :materialized} = CookingOrbs.materialize(later, @key, second)
    assert balance(final) == {0, 14}
    assert final.cooking_orbs[id] === next.cooking_orbs[id]

    assert MapSet.disjoint?(
             MapSet.new(Map.keys(final.cooking_orbs[id])),
             MapSet.new(Map.keys(final.cooking_orbs[second]))
           )

    assert {:ok, bytes} = Containers.encode(@key, final)
    assert {:ok, ^final} = Containers.decode(bytes, @key)
  end

  test "zero XP is marked once with no orb and keeps the recipe obligation" do
    recipe = "minecraft:smooth_stone"
    {before, id} = award(%Containers{}, %{recipe => 1}, %{recipe => 16_777_215})
    assert {:ok, next, :materialized} = CookingOrbs.materialize(before, @key, id)
    assert next.cooking_orbs == %{id => %{}}
    assert next.pending_awards === before.pending_awards
    assert [%{recipe: ^recipe, experience: 0, uses: 1}] = next.pending_awards[id].award.recipes
    assert {:ok, bytes} = Containers.encode(@key, next)
    assert {:ok, ^next} = Containers.decode(bytes, @key)
    assert {:ok, ^next, :already_materialized} = CookingOrbs.materialize(next, @key, id)
  end

  test "version 4 keeps the exact pre-orb encoder bytes and a large award stays compressed" do
    {before, _} = award()
    {:ok, bytes} = Containers.encode(@key, before)
    assert <<"VMCCONTS", 4, _::binary>> = bytes
    # Produced by the original 2e21e26 encoder, retained privately before this extension.
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             "09a5fef26b0267291777b266698be6ebd427be6e14dbf3ac14ac9294e2ee95ad"

    assert {:ok, ^before} = Containers.decode(bytes, @key)
    {large, id} = award(%Containers{}, %{@gold => 2_147_483_520}, %{})
    assert {:ok, next, :materialized} = CookingOrbs.materialize(large, @key, id)
    assert balance(next) == {0, 2_147_483_520}
    assert map_size(next.cooking_orbs[id]) <= 11
    assert Enum.any?(next.cooking_orbs[id], fn {_, r} -> r.count > 800_000 end)
    assert {:ok, bytes} = Containers.encode(@key, next)
    assert {:ok, ^next} = Containers.decode(bytes, @key)
  end

  test "unowned spawn stays pending; no effect is exposed without handoff" do
    span = Valimc.config(:region_size) * 16

    for position <- [{-0.000001, 64.0, 0.0}, {span * 1.0, 64.0, 0.0}, {0.0, 64.0, -0.000001}] do
      {before, id} = award(%Containers{}, %{@gold => 3}, %{}, position)
      assert {:error, :xp_orb_handoff_required} = CookingOrbs.materialize(before, @key, id)
      assert balance(before) == {3, 0}
      assert {:ok, _} = Containers.encode(@key, before)
      forged = %{before | cooking_orbs: %{id => %{}}}
      assert {:error, :invalid_container_snapshot} = Containers.encode(@key, forged)
    end

    {before, _} = award()
    assert {:error, :unknown_cooking_award} = CookingOrbs.materialize(before, @key, <<0::256>>)
    assert {:error, :invalid_cooking_orbs} = CookingOrbs.materialize(before, @key, <<0>>)
  end

  test "orphan, partial, altered or duplicated orb records cannot enter a snapshot" do
    {before, id} = award()
    {:ok, next, _} = CookingOrbs.materialize(before, @key, id)
    [{uuid, record} | _] = Map.to_list(next.cooking_orbs[id])

    for changed <- [
          %{next | pending_awards: %{}},
          %{next | cooking_orbs: %{id => %{}}},
          %{next | cooking_orbs: %{<<0::256>> => next.cooking_orbs[id]}},
          update_in(next.cooking_orbs[id], &Map.delete(&1, uuid)),
          update_in(next.cooking_orbs[id], &Map.put(&1, <<0::128>>, record)),
          put_in(next.cooking_orbs[id][uuid].count, record.count + 1),
          put_in(next.cooking_orbs[id][uuid].value, 7),
          put_in(next.cooking_orbs[id][uuid].position, {0.5, 64.25, 0}),
          put_in(next.cooking_orbs[id][uuid].position, {0.5, 65.0, 0.5})
        ] do
      assert {:error, :invalid_container_snapshot} = Containers.encode(@key, changed)
    end

    {:ok, bytes} = CookingOrbs.encode(next.cooking_orbs, @key, next.pending_awards)
    <<1::16, body::binary>> = bytes
    <<award_id::binary-size(32), 2, orb::binary-size(46), other::binary-size(46)>> = body

    for bad <- [
          <<>>,
          bytes <> <<0>>,
          binary_part(bytes, 0, byte_size(bytes) - 1),
          <<257::16>>,
          <<2::16, body::binary, body::binary>>,
          <<1::16, award_id::binary, 2, orb::binary, orb::binary>>,
          <<1::16, award_id::binary, 2, other::binary, orb::binary>>,
          :binary.copy(<<0>>, CookingOrbs.max_bytes() + 1)
        ] do
      assert {:error, :invalid_cooking_orbs} = CookingOrbs.decode(bad, @key, next.pending_awards)
    end

    {:ok, bytes} = Containers.encode(@key, next)
    # Recompute the checksum to exercise the version-5 logical decoder, not just SHA.
    for length <- 0..(byte_size(bytes) - 1)//max(1, div(byte_size(bytes), 30)) do
      assert {:error, :invalid_container_snapshot} =
               Containers.decode(binary_part(bytes, 0, length), @key)
    end

    <<prefix::binary-size(89), tail::binary>> = bytes

    bad =
      rehash(
        <<prefix::binary, 0xFFFF_FFFF::32, binary_part(tail, 4, byte_size(tail) - 4)::binary>>
      )

    assert {:error, :invalid_container_snapshot} = Containers.decode(bad, @key)
  end

  test "maximum ledger remains bounded and a refused over-capacity proposal leaves XP pending" do
    {pending, ids} =
      Enum.reduce(1..PendingCookingAwards.max_awards(), {%Containers{}, []}, fn _, {cs, ids} ->
        {cs, id} = award(cs, %{@gold => 4925}, %{})
        {cs, [id | ids]}
      end)

    final =
      Enum.reduce(ids, pending, fn id, cs ->
        {:ok, next, :materialized} = CookingOrbs.materialize(cs, @key, id)
        next
      end)

    assert balance(final) == {0, 4925 * 256}

    assert Enum.sum(Enum.map(final.cooking_orbs, fn {_, r} -> map_size(r) end)) ==
             CookingOrbs.max_records()

    assert {:ok, orb_bytes} = CookingOrbs.encode(final.cooking_orbs, @key, final.pending_awards)
    assert byte_size(orb_bytes) == CookingOrbs.max_bytes()
    assert {:ok, bytes} = Containers.encode(@key, final)
    assert {:ok, restored} = Containers.decode(bytes, @key)
    assert restored === final

    assert {:error, :cooking_award_limit} =
             PendingCookingAwards.put(
               final.pending_awards,
               @key,
               <<2::128>>,
               1,
               <<3::256>>,
               @position,
               hd(Map.values(final.pending_awards)).award
             )

    invalid = %{final | cooking_orbs: Map.put(final.cooking_orbs, <<0::256>>, %{})}
    assert {:error, :invalid_container_snapshot} = Containers.encode(@key, invalid)
    assert {:error, :invalid_container_snapshot} = CookingOrbs.materialize(invalid, @key, hd(ids))
  end
end
