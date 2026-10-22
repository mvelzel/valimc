defmodule Valimc.EntityReplicationTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{Data, EntityPackets, ItemStack, Wire}
  alias Valimc.World.{EntityReplication, EntityTracking, Entities}

  # Views as an owner publishes them at tracking tick `tick`.
  defp views(count, tick \\ 0) do
    store =
      Enum.reduce(1..count, Entities.new(), fn _, state ->
        {:ok, next, _} = Entities.create(state, {0, 0}, ItemStack.new("stone"), {0.5, 64, 0.5})
        next
      end)

    tracking = EntityTracking.sync(%EntityTracking{tick: tick}, store.views, nil)

    tracking
    |> EntityTracking.published(store.views)
    |> Map.new(fn {id, view} -> {id, Map.put(view, :tick, tick)} end)
  end

  # A region's frame ring, as `EntityPublication.frames/2` reads it.
  defp ring(frames) do
    newest = frames |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)

    fn _region, last ->
      if last == nil or last >= newest,
        do: {:ok, newest, []},
        else: {:ok, newest, Enum.filter(frames, fn {tick, _} -> tick > last end)}
    end
  end

  defp names(packets), do: Enum.map(packets, fn {id, _} -> Data.name(:play, :clientbound, id) end)

  test "an entity spawns from its row, then gets each later frame once, then is removed" do
    desired = views(1, 5)
    [{id, _}] = Map.to_list(desired)
    {packet_id, payload} = EntityPackets.move(id, {4096, 0, 0}, false)
    move = {packet_id, IO.iodata_to_binary(payload)}
    {state, packets} = EntityReplication.reconcile(EntityReplication.new(), desired, ring([]))
    assert names(packets) == ["add_entity", "set_entity_data"]

    # Tick 5 is already in the spawn; tick 6 is forwarded, once.
    frames = ring([{5, %{id => [move]}}, {6, %{id => [move]}}])
    state = %{state | regions: %{{0, 0} => 4}}
    {state, packets} = EntityReplication.reconcile(state, desired, frames)
    assert packets == [move]
    assert {^state, []} = EntityReplication.reconcile(state, desired, frames)

    {state, packets} = EntityReplication.reconcile(state, %{}, frames)
    assert names(packets) == ["remove_entities"] and state.tracked == %{}
    {1, rest} = Wire.take_varint(elem(hd(packets), 1))
    assert {^id, <<>>} = Wire.take_varint(rest)
  end

  test "an entity under another owner, or behind a gap, resyncs and is never respawned" do
    desired = views(1)
    [{id, view}] = Map.to_list(desired)
    {state, _} = EntityReplication.reconcile(EntityReplication.new(), desired, ring([]))
    handed = %{id => %{view | epoch: make_ref(), base: {3.5, 64.0, 0.5}, tick: 9}}
    {state, packets} = EntityReplication.reconcile(state, handed, ring([]))
    assert names(packets) == ["entity_position_sync", "set_entity_motion", "set_entity_data"]
    assert state.tracked[id].since == 9

    gap = fn _, _ -> {:gap, 100} end
    {state, packets} = EntityReplication.reconcile(state, handed, gap)
    assert names(packets) == ["entity_position_sync", "set_entity_motion", "set_entity_data"]
    assert state.regions == %{{0, 0} => 100}
  end

  test "new entities are paced in id order and the maximum population leaves in one batch" do
    desired = Enum.reduce(1..4, %{}, fn _, acc -> Map.merge(acc, views(256)) end)
    assert map_size(desired) == 1024

    state =
      Enum.reduce(1..16, EntityReplication.new(), fn _, state ->
        {next, packets} = EntityReplication.reconcile(state, desired, ring([]))
        assert length(packets) == 128
        next
      end)

    assert map_size(state.tracked) == 1024
    {cleared, [packet]} = EntityReplication.reconcile(state, %{}, ring([]))
    assert cleared.tracked == %{}
    assert Valimc.World.EntityView.packet_bytes(packet) < 262_144
    assert {1024, _} = Wire.take_varint(elem(packet, 1))
  end
end
