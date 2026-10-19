defmodule Valimc.CookingOrbBodiesTest do
  use ExUnit.Case, async: true

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbs,
    CookingOrbBodies,
    CookingOrbConsumptions,
    CookingOrbTransfers,
    ExperienceTransfers,
    PendingCookingAwards
  }

  @key {0, 0}
  @source <<41::128>>
  @recipe "minecraft:gold_ingot_from_smelting_gold_ore"

  defp fixture(amount \\ 6, at \\ {8.5, 64.25, 8.5}) do
    {uses, draws} =
      if amount == 0,
        do: {%{"minecraft:smooth_stone" => 1}, %{"minecraft:smooth_stone" => 16_777_215}},
        else: {%{@recipe => amount}, %{}}

    {:ok, award} = Valimc.CookingAwards.plan(uses, draws)
    digest = :crypto.hash(:sha256, "body fixture")
    {:ok, pending, id} = PendingCookingAwards.put(%{}, @key, @source, 1, digest, at, award)

    cs = %Containers{
      pending_awards: pending,
      receipts: %{
        @source => %{sequence: 1, digest: ContainerTransfers.result_digest(digest, :applied)}
      }
    }

    {cs, id}
  end

  defp local(amount \\ 6) do
    {cs, id} = fixture(amount)
    {:ok, cs, :materialized} = CookingOrbs.materialize(cs, @key, id)
    {cs, id}
  end

  defp init(cs, id, key \\ @key) do
    decisions =
      for {uuid, b} <- CookingOrbs.owned_records(cs)[id],
          b.count > Map.get(cs.orb_consumption.counts, uuid, 0),
          into: %{},
          do: {uuid, {{0, 0, 0}, {0.2, 0.7, 0.9}}}

    assert {:ok, proposal} = CookingOrbBodies.initialize(cs, key, id, decisions)
    assert {:ok, next, :applied} = CookingOrbBodies.install(cs, key, proposal)
    {next, proposal}
  end

  defp advance(cs, id, age, at \\ nil) do
    updates =
      for {uuid, row} <- cs.orb_bodies.awards[id],
          into: %{},
          do:
            {uuid,
             %{
               expected_revision: row.revision,
               position: at || row.position,
               velocity: row.velocity,
               age: age,
               on_ground: row.on_ground
             }}

    CookingOrbBodies.checkpoint(cs, @key, updates)
  end

  defp cold(cs, key \\ @key) do
    assert {:ok, bytes} = Containers.encode(key, cs)
    assert {:ok, restored} = Containers.decode(bytes, key)
    assert restored === cs
    assert {:ok, ^bytes} = Containers.encode(key, restored)
    restored
  end

  test "unused bodies preserve every legacy version; local/imported/partly consumed births migrate atomically" do
    empty = %Containers{}
    {:ok, reserved, _} = ContainerTransfers.reserve(empty, @source)
    {:ok, cooking, _} = Containers.create_cooking(empty, @key, {2, 64, 2}, :furnace)
    {pending, id} = fixture()
    {:ok, local, _} = CookingOrbs.materialize(pending, @key, id)
    {remote, remote_id} = fixture(6, {128.5, 64.25, 8.5})
    {:ok, _, request, _} = CookingOrbTransfers.prepare(remote, @key, remote_id)
    {:ok, imported, _} = CookingOrbTransfers.accept(empty, {1, 0}, request)
    [uuid] = Map.keys(local.cooking_orbs[id])
    {:ok, consumed} = CookingOrbConsumptions.take(local, uuid, 3, 0)

    for {cs, key, version} <- [
          {empty, @key, 1},
          {reserved, @key, 2},
          {cooking, @key, 3},
          {pending, @key, 4},
          {local, @key, 5},
          {imported, {1, 0}, 6},
          {consumed, @key, 7}
        ] do
      assert {:ok, <<"VMCCONTS", ^version, _::binary>>} = Containers.encode(key, cs)
      assert cold(cs, key).orb_bodies == CookingOrbBodies.new()
    end

    for {cs, key, id} <- [{local, @key, id}, {imported, {1, 0}, remote_id}, {consumed, @key, id}] do
      {next, _} = init(cs, id, key)
      assert {:ok, <<"VMCCONTS", 8, _::binary>>} = Containers.encode(key, next)
      assert Map.delete(cold(next, key), :orb_bodies) == Map.delete(cs, :orb_bodies)
    end
  end

  test "initialization resolves launch once and retains complete markers including zero and collected awards" do
    {cs, id} = local(8)
    {next, proposal} = init(cs, id)
    assert cs.orb_bodies == CookingOrbBodies.new()
    assert map_size(next.orb_bodies.awards[id]) == 2
    assert {:ok, replay} = CookingOrbBodies.initialize(next, @key, id, %{})
    assert replay.bodies == proposal.bodies
    assert {:ok, ^next, :already_applied} = CookingOrbBodies.install(next, @key, proposal)
    assert {:error, _} = CookingOrbBodies.initialize(cs, @key, id, %{})
    assert {:error, _} = CookingOrbBodies.initialize(cs, @key, <<0::256>>, %{})
    [uuid | _] = Map.keys(next.cooking_orbs[id])
    value = next.cooking_orbs[id][uuid].value
    assert {:ok, taken} = CookingOrbConsumptions.take(next, uuid, value, 0)
    assert {:ok, ^taken, :already_applied} = CookingOrbBodies.install(taken, @key, proposal)

    {zero, id} = local(0)
    {zero, _} = init(zero, id)
    assert cold(zero).orb_bodies.awards[id] == %{}
    {collected, id} = local(1)
    [uuid] = Map.keys(collected.cooking_orbs[id])
    {:ok, collected} = CookingOrbConsumptions.take(collected, uuid, 1, 0)
    {collected, _} = init(collected, id)
    assert CookingOrbBodies.project(cold(collected))[id] == %{}
  end

  test "current pose authorizes contact; expiry retires only remaining units and rejects stale pickup" do
    {cs, id} = local()
    {cs, _} = init(cs, id)
    [uuid] = Map.keys(cs.cooking_orbs[id])
    moved_at = {28.5, 64.25, 8.5}
    {:ok, p} = advance(cs, id, 5999, moved_at)
    {:ok, moved, :applied} = CookingOrbBodies.install(cs, @key, p)
    source = <<19::128>>

    actor = fn at ->
      {:ok, geometry} = Valimc.Physics.PlayerPose.geometry(:standing, at)

      %{
        uuid: source,
        entity_id: 17,
        health: %{value: 20.0},
        game_mode: %{current: :survival},
        box: geometry.box,
        expires: 100
      }
    end

    request = %{
      source: source,
      collector: 17,
      position: {28, 64, 8},
      value: 3,
      orb_uuid: uuid,
      consumed: 0
    }

    refute ExperienceTransfers.eligible?(moved, request, actor.({8.5, 64.25, 8.5}), 0)
    assert ExperienceTransfers.eligible?(moved, request, actor.(moved_at), 0)
    {:ok, taken} = CookingOrbConsumptions.take(moved, uuid, 3, 0)
    {:ok, p} = advance(taken, id, 6000)
    {:ok, expired, :applied} = CookingOrbBodies.install(taken, @key, p)
    assert expired.orb_bodies.awards[id][uuid].expired == 1
    assert expired.orb_consumption == taken.orb_consumption
    assert CookingOrbBodies.project(cold(expired))[id] == %{}
    refute ExperienceTransfers.eligible?(expired, %{request | consumed: 1}, actor.(moved_at), 0)
    assert {:error, _} = CookingOrbConsumptions.take(expired, uuid, 3, 1)
    assert {:error, _} = advance(expired, id, 6000)
    assert {:ok, replay} = CookingOrbBodies.initialize(expired, @key, id, %{})
    assert {:ok, ^expired, :already_applied} = CookingOrbBodies.install(expired, @key, replay)
    assert expired.cooking_orbs == cs.cooking_orbs and expired.pending_awards == cs.pending_awards
  end

  test "proposals fence consumption and body changes, preserve unrelated edits and refuse rewind or handoff" do
    {cs, id} = local()
    {cs, _} = init(cs, id)
    [uuid] = Map.keys(cs.cooking_orbs[id])
    {:ok, p} = advance(cs, id, 10)
    {:ok, taken} = CookingOrbConsumptions.take(cs, uuid, 3, 0)
    assert {:error, :stale_orb_body_proposal} = CookingOrbBodies.install(taken, @key, p)
    {:ok, chest, _} = Containers.create(cs, @key, {4, 64, 4}, 3)
    {:ok, applied, :applied} = CookingOrbBodies.install(chest, @key, p)
    assert applied.entries == chest.entries and applied.sequence == chest.sequence
    assert {:error, _} = advance(applied, id, 9)
    assert {:error, _} = advance(applied, id, 11, {128.5, 64.0, 8.5})
    forged = %{expected: CookingOrbBodies.fence(applied), bodies: %{revision: 3, awards: %{}}}
    assert {:error, _} = CookingOrbBodies.install(applied, @key, forged)
    {:ok, later} = advance(applied, id, 11)
    {:ok, later, :applied} = CookingOrbBodies.install(applied, @key, later)
    assert {:error, :stale_orb_body_proposal} = CookingOrbBodies.install(later, @key, p)
  end

  test "codec refuses incomplete markers, orphans, inconsistent retirement, flags and nonfinite vectors" do
    {cs, id} = local(8)
    {cs, _} = init(cs, id)
    [uuid | _] = Map.keys(cs.orb_bodies.awards[id])
    row = cs.orb_bodies.awards[id][uuid]

    for row <- [
          %{row | age: 6000},
          %{row | expired: 1},
          %{row | revision: 2},
          %{row | velocity: {65.0, 0.0, 0.0}},
          %{row | position: {128.5, 64.0, 8.5}}
        ] do
      bad = put_in(cs.orb_bodies.awards[id][uuid], row)
      assert {:error, _} = Containers.encode(@key, bad)
    end

    incomplete = update_in(cs.orb_bodies.awards[id], &Map.delete(&1, uuid))
    assert {:error, _} = Containers.encode(@key, incomplete)
    assert CookingOrbBodies.fetch(incomplete, uuid) == nil
    bad = put_in(cs.orb_bodies.awards[<<0::256>>], cs.orb_bodies.awards[id])
    assert {:error, _} = Containers.encode(@key, bad)
    {:ok, bytes} = CookingOrbBodies.encode(cs.orb_bodies, @key, cs)
    assert {:error, _} = CookingOrbBodies.decode(bytes <> <<0>>, @key, cs)

    replace = fn offset, size, replacement ->
      binary_part(bytes, 0, offset) <>
        replacement <> binary_part(bytes, offset + size, byte_size(bytes) - offset - size)
    end

    assert {:error, _} = CookingOrbBodies.decode(replace.(119, 1, <<4>>), @key, cs)

    assert {:error, _} =
             CookingOrbBodies.decode(replace.(124, 81, binary_part(bytes, 43, 81)), @key, cs)

    assert {:error, _} =
             CookingOrbBodies.decode(replace.(67, 8, <<0x7FF8000000000000::64>>), @key, cs)
  end

  test "full regional markers reach their exact bound without a process or row per XP point" do
    {:ok, award} = Valimc.CookingAwards.plan(%{@recipe => 4925}, %{})

    {cs, bodies} =
      Enum.reduce(1..256, {%Containers{}, %{}}, fn n, {cs, bodies} ->
        digest = :crypto.hash(:sha256, <<n::32>>)

        {:ok, pending, id} =
          PendingCookingAwards.put(
            cs.pending_awards,
            @key,
            @source,
            n,
            digest,
            {8.5, 64.25, 8.5},
            award
          )

        records = CookingOrbs.records(id, pending[id])

        rows =
          Map.new(records, fn {uuid, birth} ->
            {uuid,
             %{
               position: birth.position,
               velocity: {0.0, 0.0, 0.0},
               revision: n,
               age: 0,
               on_ground: false,
               no_gravity: false,
               expired: 0
             }}
          end)

        {%{
           cs
           | pending_awards: pending,
             cooking_orbs: Map.put(cs.cooking_orbs, id, records),
             receipts: %{
               @source => %{
                 sequence: n,
                 digest: ContainerTransfers.result_digest(digest, :applied)
               }
             }
         }, Map.put(bodies, id, rows)}
      end)

    cs = %{cs | orb_bodies: %{revision: 256, awards: bodies}}
    assert Enum.sum(Enum.map(bodies, fn {_, rows} -> map_size(rows) end)) == 2816
    assert {:ok, bytes} = CookingOrbBodies.encode(cs.orb_bodies, @key, cs)
    assert byte_size(bytes) == CookingOrbBodies.max_bytes()
    assert cold(cs) == cs
  end

  test "input widths and exhausted generations refuse before launch or transition work" do
    {cs, id} = local(1)
    decisions = for n <- 1..12, into: %{}, do: {<<n::128>>, {{0, 0, 0}, {0.5, 0.5, 0.5}}}
    assert {:error, _} = CookingOrbBodies.initialize(cs, @key, id, decisions)
    {cs, _} = init(cs, id)
    too_many = for n <- 1..257, into: %{}, do: {<<n::256>>, %{}}
    p = %{expected: CookingOrbBodies.fence(cs), bodies: %{revision: 2, awards: too_many}}
    assert {:error, _} = CookingOrbBodies.install(cs, @key, p)
    [uuid] = Map.keys(cs.orb_bodies.awards[id])
    row = cs.orb_bodies.awards[id][uuid]
    too_many = for n <- 1..12, into: %{}, do: {<<n::128>>, row}
    p = %{p | bodies: %{revision: 2, awards: %{id => too_many}}}
    assert {:error, _} = CookingOrbBodies.install(cs, @key, p)
    exhausted = put_in(cs.orb_bodies.revision, 18_446_744_073_709_551_615)
    assert {:ok, _} = Containers.encode(@key, exhausted)
    assert {:error, _} = advance(exhausted, id, 1)
    assert exhausted.orb_bodies.awards == cs.orb_bodies.awards
  end
end
