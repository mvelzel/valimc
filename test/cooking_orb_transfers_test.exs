defmodule Valimc.CookingOrbTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.CookingAwards

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
