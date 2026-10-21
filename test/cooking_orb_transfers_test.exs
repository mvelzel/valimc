defmodule Valimc.CookingOrbTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.CookingAwards
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbs,
    CookingOrbTransfers,
    PendingCookingAwards
  }

  @source {0, 0}
  @dest {1, 0}
  @recipe "minecraft:gold_ingot_from_smelting_gold_ore"

  defp award(state, key, pos, n \\ 1, uses \\ %{@recipe => 6}, draws \\ %{}) do
    source = <<1::128>>
    digest = :crypto.hash(:sha256, <<n::32>>)
    {:ok, decision} = CookingAwards.plan(uses, draws)

    {:ok, awards, id} =
      PendingCookingAwards.put(state.pending_awards, key, source, n, digest, pos, decision)

    receipt = %{sequence: n, digest: ContainerTransfers.result_digest(digest, :applied)}
    {%{state | pending_awards: awards, receipts: Map.put(state.receipts, source, receipt)}, id}
  end

  defp cold(state, key) do
    assert {:ok, bytes} = Containers.encode(key, state)
    assert {:ok, restored} = Containers.decode(bytes, key)
    assert restored === state
    assert {:ok, ^bytes} = Containers.encode(key, restored)
    restored
  end

  test "source intent, destination adoption and exact acknowledgement are replayable across cold snapshots" do
    {source, local_id} = award(%Containers{}, @source, {0.5, 64.25, 0.5})
    {:ok, source, _} = CookingOrbs.materialize(source, @source, local_id)
    {source, id} = award(source, @source, {128.5, 64.25, 0.5}, 2)

    assert {:error, :missing_cooking_orb_intent} =
             CookingOrbTransfers.request(source, @source, id)

    assert {:ok, routed, request, :prepared} = CookingOrbTransfers.prepare(source, @source, id)
    assert routed.cooking_orbs === source.cooking_orbs
    assert routed.pending_awards === source.pending_awards
    assert routed.receipts === source.receipts
    routed = cold(routed, @source)
    assert {:ok, ^request} = CookingOrbTransfers.request(routed, @source, id)

    assert {:ok, ^routed, ^request, :already_prepared} =
             CookingOrbTransfers.prepare(routed, @source, id)

    assert {:ok, bytes} = CookingOrbTransfers.encode_request(request)
    assert {:ok, ^request} = CookingOrbTransfers.decode_request(bytes)
    assert {:ok, digest} = CookingOrbTransfers.digest(request)
    assert {:ok, records} = CookingOrbTransfers.records(request)
    assert [%{value: 3, count: 2, position: {128.5, 64.25, 0.5}}] = Map.values(records)

    {:ok, dest, chest} = Containers.create(%Containers{}, @dest, {130, 64, 2}, 3)
    slots = put_elem(chest.slots, 0, ItemStack.new("diamond", 3))
    {:ok, dest, _} = Containers.replace(dest, {130, 64, 2}, chest.revision, slots)
    assert {:ok, adopted, :applied} = CookingOrbTransfers.accept(dest, @dest, request)
    assert adopted.entries === dest.entries and adopted.sequence == dest.sequence
    assert adopted.pending_awards == %{} and adopted.cooking_orbs == %{}
    adopted = cold(adopted, @dest)
    assert {:ok, ^adopted, :already_applied} = CookingOrbTransfers.accept(adopted, @dest, request)

    assert {:ok, ^routed, ^request, :already_prepared} =
             CookingOrbTransfers.prepare(routed, @source, id)

    assert {:ok, done, :delivered} = CookingOrbTransfers.acknowledge(routed, @source, id, digest)
    done = cold(done, @source)
    assert done.pending_awards === source.pending_awards
    assert done.cooking_orbs === source.cooking_orbs

    assert {:ok, ^done, :already_delivered} =
             CookingOrbTransfers.acknowledge(done, @source, id, digest)

    assert {:ok, ^done, ^request, :already_delivered} =
             CookingOrbTransfers.prepare(done, @source, id)

    assert {:ok, ^adopted, :already_applied} = CookingOrbTransfers.accept(adopted, @dest, request)
  end

  test "negative and exact region boundaries route by the authoritative spawn pose" do
    for {position, destination} <- [
          {{-0.000001, 64.0, 0.0}, {-1, 0}},
          {{128.0, 64.0, 0.0}, {1, 0}},
          {{0.0, 64.0, -0.000001}, {0, -1}}
        ] do
      {cs, id} = award(%Containers{}, @source, position)
      assert {:ok, routed, request, :prepared} = CookingOrbTransfers.prepare(cs, @source, id)
      assert request.destination == destination

      assert {:ok, adopted, :applied} =
               CookingOrbTransfers.accept(%Containers{}, destination, request)

      assert cold(routed, @source) == routed and cold(adopted, destination) == adopted
    end
  end

  test "legacy v5 bytes stay exact and a complete 107-recipe request fits its record bound" do
    {local, id} = award(%Containers{}, @source, {0.5, 64.25, 0.5})
    {:ok, local, _} = CookingOrbs.materialize(local, @source, id)
    {:ok, bytes} = Containers.encode(@source, local)
    # Captured from frozen ed06d5a, before adding transfer storage.
    assert Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) ==
             "26b929d10fd6a9f54dff2654bb9bafa4ec67d3859fc78673fb453a58e5ca068a"

    assert cold(local, @source) == local
    recipes = JSON.decode!(File.read!("priv/crafting/cooking.json"))["recipes"]
    uses = Map.new(recipes, &{&1["recipe"], 10})
    draws = Map.new(uses, fn {r, _} -> {r, 0} end)
    {cs, id} = award(%Containers{}, @source, {128.5, 64.25, 0.5}, 1, uses, draws)
    {:ok, _, request, _} = CookingOrbTransfers.prepare(cs, @source, id)
    {:ok, wire} = CookingOrbTransfers.encode_request(request)
    assert byte_size(wire) == CookingOrbTransfers.max_request_bytes()
    assert {:ok, ^request} = CookingOrbTransfers.decode_request(wire)
    assert {:ok, adopted, _} = CookingOrbTransfers.accept(%Containers{}, @dest, request)
    assert cold(adopted, @dest) == adopted
  end
end
