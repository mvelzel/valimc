defmodule Valimc.CookingOrbTransfersTest do
  use ExUnit.Case, async: true
  alias Valimc.CookingAwards
  alias Valimc.Protocol.ItemStack

  alias Valimc.World.{
    Containers,
    ContainerTransfers,
    CookingOrbs,
    CookingOrbConsumptions,
    CookingOrbRuntime,
    CookingOrbTransfers,
    PendingCookingAwards
  }

  @source {0, 0}
  @dest {1, 0}
  @recipe "minecraft:gold_ingot_from_smelting_gold_ore"

  defp award(
         state \\ %Containers{},
         key \\ @source,
         pos \\ {128.5, 64.25, 0.5},
         n \\ 1,
         uses \\ %{@recipe => 6},
         draws \\ %{}
       ) do
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

  test "import replay and cold publication retain consumed units without rewriting adoption proofs" do
    {source, id} = award()
    {:ok, routed, request, _} = CookingOrbTransfers.prepare(source, @source, id)
    {:ok, adopted, _} = CookingOrbTransfers.accept(%Containers{}, @dest, request)
    {:ok, records} = CookingOrbTransfers.records(request)
    [{uuid, %{value: 3, count: 2}}] = Map.to_list(records)

    {:ok, half} = CookingOrbConsumptions.take(adopted, uuid, 3, 0)
    half = cold(half, @dest)
    assert {:ok, ^half, :already_applied} = CookingOrbTransfers.accept(half, @dest, request)
    assert {:error, _} = CookingOrbConsumptions.take(half, uuid, 3, 0)
    assert {:refresh, publication} = CookingOrbRuntime.plan(half, @dest, 11, %CookingOrbRuntime{})
    assert [%{uuid: ^uuid, count: 1, consumed: 1}] = Map.values(publication.views)
    assert publication.ledger[id] == records

    {:ok, consumed} = CookingOrbConsumptions.take(half, uuid, 3, 1)
    consumed = cold(consumed, @dest)

    assert {:ok, ^consumed, :already_applied} =
             CookingOrbTransfers.accept(consumed, @dest, request)

    assert {:refresh, empty} =
             CookingOrbRuntime.plan(consumed, @dest, 12, %CookingOrbRuntime{
               views: publication.views
             })

    assert empty.views == %{}
    assert empty.ledger[id] == records
    assert consumed.orb_transfers == adopted.orb_transfers
    assert consumed.pending_awards == %{} and consumed.cooking_orbs == %{}
    assert {:error, _} = CookingOrbConsumptions.take(consumed, uuid, 3, 2)

    {:ok, digest} = CookingOrbTransfers.digest(request)

    assert {:ok, settled, :delivered} =
             CookingOrbTransfers.acknowledge(routed, @source, id, digest)

    assert cold(settled, @source).pending_awards == source.pending_awards

    assert {:ok, ^consumed, :already_applied} =
             CookingOrbTransfers.accept(consumed, @dest, request)
  end

  test "zero XP persists adoption and routing without an entity and keeps recipe delivery" do
    recipe = "minecraft:smooth_stone"

    {cs, id} =
      award(%Containers{}, @source, {128.5, 64.25, 0.5}, 1, %{recipe => 1}, %{
        recipe => 16_777_215
      })

    {:ok, routed, request, _} = CookingOrbTransfers.prepare(cs, @source, id)
    assert {:ok, %{}} = CookingOrbTransfers.records(request)
    {:ok, adopted, :applied} = CookingOrbTransfers.accept(%Containers{}, @dest, request)
    assert cold(adopted, @dest).orb_transfers.incoming[id] == request
    {:ok, digest} = CookingOrbTransfers.digest(request)
    {:ok, done, :delivered} = CookingOrbTransfers.acknowledge(routed, @source, id, digest)

    assert cold(done, @source).pending_awards[id].award.recipes ==
             cs.pending_awards[id].award.recipes
  end

  test "conflicting decisions, wrong endpoints and acknowledgements cannot settle or duplicate an award" do
    {cs, id} = award()
    {:ok, routed, request, _} = CookingOrbTransfers.prepare(cs, @source, id)
    {:ok, adopted, _} = CookingOrbTransfers.accept(%Containers{}, @dest, request)
    changed = put_in(request.award.position, {129.5, 64.25, 0.5})
    assert {:ok, _} = CookingOrbTransfers.encode_request(changed)

    assert {:error, :cooking_orb_transfer_conflict} =
             CookingOrbTransfers.accept(adopted, @dest, changed)

    other_digest = :crypto.hash(:sha256, "conflicting source decision")

    {:ok, other, other_id} =
      PendingCookingAwards.put(
        %{},
        @source,
        request.award.source,
        request.award.sequence,
        other_digest,
        request.award.position,
        request.award.award
      )

    conflicting = %{request | id: other_id, award: other[other_id]}
    assert {:ok, _} = CookingOrbTransfers.encode_request(conflicting)

    assert {:error, :cooking_orb_transfer_conflict} =
             CookingOrbTransfers.accept(adopted, @dest, conflicting)

    forged = %{
      adopted
      | orb_transfers: %{
          revision: 2,
          outgoing: %{},
          incoming: %{id => request, other_id => conflicting}
        }
    }

    assert {:error, :invalid_container_snapshot} = Containers.encode(@dest, forged)

    {:ok, wrong_digest} = CookingOrbTransfers.digest(changed)

    assert {:error, :stale_cooking_orb_acknowledgement} =
             CookingOrbTransfers.acknowledge(routed, @source, id, wrong_digest)

    assert {:error, :stale_cooking_orb_acknowledgement} =
             CookingOrbTransfers.acknowledge(cs, @source, id, wrong_digest)

    assert {:error, :invalid_cooking_orb_transfer} =
             CookingOrbTransfers.accept(adopted, @source, request)

    assert {:error, :unknown_cooking_award} = CookingOrbTransfers.prepare(cs, @source, <<0::256>>)

    for bad <- [
          Map.put(request, :extra, true),
          %{request | id: <<0::256>>},
          %{request | source: @dest},
          %{request | destination: {2, 0}},
          put_in(request.award.award.experience, 7)
        ] do
      assert {:error, _} = CookingOrbTransfers.encode_request(bad)
      assert {:error, _} = CookingOrbTransfers.accept(%Containers{}, @dest, bad)
    end

    {local, local_id} = award(%Containers{}, @source, {0.5, 64.25, 0.5})
    assert {:error, _} = CookingOrbTransfers.prepare(local, @source, local_id)
    {:ok, local, _} = CookingOrbs.materialize(local, @source, local_id)

    assert {:error, :cooking_orb_already_local} =
             CookingOrbTransfers.prepare(local, @source, local_id)
  end

  test "combined imported and local capacity refuses new effects but retains all replay receipts" do
    {source, requests} =
      Enum.reduce(1..256, {%Containers{}, %{}}, fn n, {cs, requests} ->
        {cs, id} = award(cs, @source, {128.5, 64.25, 0.5}, n)

        {cs,
         Map.put(requests, id, %{
           source: @source,
           destination: @dest,
           id: id,
           award: cs.pending_awards[id]
         })}
      end)

    routed = %{
      source
      | orb_transfers: %{
          revision: 256,
          outgoing: Map.new(requests, fn {id, _} -> {id, :pending} end),
          incoming: %{}
        }
    }

    assert cold(routed, @source) == routed
    full = %Containers{orb_transfers: %{revision: 256, outgoing: %{}, incoming: requests}}
    assert cold(full, @dest) == full
    [request | _] = Map.values(requests)
    assert {:ok, ^full, :already_applied} = CookingOrbTransfers.accept(full, @dest, request)
    {extra, id} = award(%Containers{}, {2, 0}, {128.5, 64.25, 0.5})
    {:ok, _, extra_request, _} = CookingOrbTransfers.prepare(extra, {2, 0}, id)

    assert {:error, :cooking_orb_transfer_capacity} =
             CookingOrbTransfers.accept(full, @dest, extra_request)

    {with_local, local_id} = award(full, @dest, {129.5, 64.25, 0.5})
    assert {:error, :cooking_orb_capacity} = CookingOrbs.materialize(with_local, @dest, local_id)

    partial =
      update_in(full.orb_transfers, fn t ->
        %{t | revision: 255, incoming: Map.delete(t.incoming, request.id)}
      end)

    {partial, local_id} = award(partial, @dest, {129.5, 64.25, 0.5})
    {:ok, partial, _} = CookingOrbs.materialize(partial, @dest, local_id)
    assert cold(partial, @dest) == partial

    assert {:error, :cooking_orb_transfer_capacity} =
             CookingOrbTransfers.accept(partial, @dest, request)
  end

  test "canonical transfer bytes reject corruption, duplicates, unsorted rows and forged revisions" do
    {cs, id} = award()
    {:ok, routed, request, _} = CookingOrbTransfers.prepare(cs, @source, id)
    {routed, id2} = award(routed, @source, {129.5, 64.25, 0.5}, 2)
    {:ok, routed, _, _} = CookingOrbTransfers.prepare(routed, @source, id2)

    {:ok, bytes} =
      CookingOrbTransfers.encode(routed.orb_transfers, @source, routed.pending_awards, %{})

    <<header::binary-size(12), a::binary-size(33), b::binary-size(33)>> = bytes

    for bad <- [
          <<>>,
          bytes <> <<0>>,
          binary_part(bytes, 0, byte_size(bytes) - 1),
          <<header::binary, b::binary, a::binary>>,
          <<header::binary, a::binary, a::binary>>,
          <<0::64, 2::16, 0::16, a::binary, b::binary>>,
          <<0::64, 257::16, 0::16>>,
          :binary.copy(<<0>>, CookingOrbTransfers.max_bytes() + 1)
        ] do
      assert {:error, _} = CookingOrbTransfers.decode(bad, @source, routed.pending_awards, %{})
    end

    {:ok, wire} = CookingOrbTransfers.encode_request(request)

    for bad <- [
          <<>>,
          wire <> <<0>>,
          binary_part(wire, 0, byte_size(wire) - 1),
          :binary.copy(<<0>>, CookingOrbTransfers.max_request_bytes() + 1)
        ] do
      assert {:error, _} = CookingOrbTransfers.decode_request(bad)
    end

    for bad <- [
          put_in(routed.orb_transfers.revision, 0),
          put_in(routed.orb_transfers.outgoing[id], :other),
          put_in(routed.orb_transfers.outgoing[<<0::256>>], :pending),
          %{routed | pending_awards: %{}},
          %{routed | cooking_orbs: %{id => CookingOrbs.records(id, request.award)}}
        ] do
      assert {:error, :invalid_container_snapshot} = Containers.encode(@source, bad)
    end

    {:ok, imported, _} = CookingOrbTransfers.accept(%Containers{}, @dest, request)
    assert {:ok, snapshot} = Containers.encode(@dest, imported)
    assert <<"VMCCONTS", 6, _::binary>> = snapshot
    assert {:error, _} = Containers.decode(snapshot <> <<0>>, @dest)
    assert {:error, _} = Containers.decode(snapshot, @source)
  end

  test "incoming rows are canonical and immutable record bytes reject another source region" do
    {cs, id} = award()
    {:ok, _, request, _} = CookingOrbTransfers.prepare(cs, @source, id)
    {cs, id2} = award(cs, @source, {129.5, 64.25, 0.5}, 2)
    {:ok, _, other, _} = CookingOrbTransfers.prepare(cs, @source, id2)
    {:ok, dest, _} = CookingOrbTransfers.accept(%Containers{}, @dest, request)
    {:ok, dest, _} = CookingOrbTransfers.accept(dest, @dest, other)
    {:ok, bytes} = CookingOrbTransfers.encode(dest.orb_transfers, @dest, %{}, %{})

    <<header::binary-size(12), size_a::16, a::binary-size(size_a), size_b::16,
      b::binary-size(size_b)>> = bytes

    for bad <- [
          <<header::binary, size_b::16, b::binary, size_a::16, a::binary>>,
          <<header::binary, size_a::16, a::binary, size_a::16, a::binary>>
        ] do
      assert {:error, _} = CookingOrbTransfers.decode(bad, @dest, %{}, %{})
    end

    assert {:ok, record} = PendingCookingAwards.encode_record(@source, id, request.award)
    assert {:ok, ^id, decision} = PendingCookingAwards.decode_record(record, @source)
    assert decision === request.award

    for bad <- [record <> <<0>>, binary_part(record, 0, byte_size(record) - 1), <<>>] do
      assert {:error, _} = PendingCookingAwards.decode_record(bad, @source)
    end

    assert {:error, _} = PendingCookingAwards.decode_record(record, @dest)
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

  test "all 256 full-recipe imports and source intents reach the exact ledger byte bound" do
    recipes = JSON.decode!(File.read!("priv/crafting/cooking.json"))["recipes"]
    uses = Map.new(recipes, &{&1["recipe"], 10})
    draws = Map.new(uses, fn {r, _} -> {r, 0} end)

    {source, outgoing, incoming} =
      Enum.reduce(1..256, {%Containers{}, %{}, %{}}, fn n, {source, outgoing, incoming} ->
        {source, id} = award(source, @source, {128.5, 64.25, 0.5}, n, uses, draws)
        {other, imported_id} = award(%Containers{}, {-1, 0}, {0.5, 64.25, 0.5}, n, uses, draws)

        request = %{
          source: {-1, 0},
          destination: @source,
          id: imported_id,
          award: other.pending_awards[imported_id]
        }

        {source, Map.put(outgoing, id, :pending), Map.put(incoming, imported_id, request)}
      end)

    full = %{source | orb_transfers: %{revision: 512, outgoing: outgoing, incoming: incoming}}

    assert {:ok, bytes} =
             CookingOrbTransfers.encode(full.orb_transfers, @source, full.pending_awards, %{})

    assert byte_size(bytes) == CookingOrbTransfers.max_bytes()
    assert {:ok, transfers} = CookingOrbTransfers.decode(bytes, @source, full.pending_awards, %{})
    assert transfers == full.orb_transfers
    assert cold(full, @source) == full
  end
end
