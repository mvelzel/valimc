defmodule Valimc.CookingOrbBodiesTest do
  use ExUnit.Case, async: true

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbs,
    CookingOrbBodies,
    CookingOrbConsumptions,
    CookingOrbTransfers,
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

  defp local(amount) do
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
end
