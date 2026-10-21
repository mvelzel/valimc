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
end
