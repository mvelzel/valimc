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

  defp init(cs, id, key) do
    decisions =
      for {uuid, b} <- CookingOrbs.owned_records(cs)[id],
          b.count > Map.get(cs.orb_consumption.counts, uuid, 0),
          into: %{},
          do: {uuid, {{0, 0, 0}, {0.2, 0.7, 0.9}}}

    assert {:ok, proposal} = CookingOrbBodies.initialize(cs, key, id, decisions)
    assert {:ok, next, :applied} = CookingOrbBodies.install(cs, key, proposal)
    {next, proposal}
  end

  defp cold(cs, key) do
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
end
