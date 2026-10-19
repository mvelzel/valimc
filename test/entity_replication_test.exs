defmodule Valimc.EntityReplicationTest do
  use ExUnit.Case, async: true
  alias Valimc.Protocol.{Data, ItemStack, Wire}
  alias Valimc.World.{EntityReplication, Items}

  defp views(count, stack \\ ItemStack.new("stone")) do
    Enum.reduce(1..count, Items.new(), fn _, state ->
      {:ok, next, _} = Items.create(state, {0, 0}, stack, {0, 64, 0})
      next
    end).views
  end

  defp names(packets), do: Enum.map(packets, fn {id, _} -> Data.name(:play, :clientbound, id) end)

  test "spawn precedes metadata; updates retain identity and removal precedes replacement" do
    desired = views(1)
    [{id, view}] = Map.to_list(desired)
    {state, packets} = EntityReplication.reconcile(EntityReplication.new(), desired)
    assert names(packets) == ["add_entity", "set_entity_data"]
    assert {^state, []} = EntityReplication.reconcile(state, desired)
    changed = %{desired | id => %{view | revision: 2, metadata_revision: 2}}
    {state, packets} = EntityReplication.reconcile(state, changed)
    assert names(packets) == ["set_entity_data"]
    replaced = %{desired | id => %{view | epoch: make_ref()}}
    {state, packets} = EntityReplication.reconcile(state, replaced)
    assert names(packets) == ["remove_entities", "add_entity", "set_entity_data"]
    {state, packets} = EntityReplication.reconcile(state, %{})
    assert names(packets) == ["remove_entities"]
    assert state.tracked == %{}
    {1, rest} = Wire.take_varint(elem(hd(packets), 1))
    assert {^id, <<>>} = Wire.take_varint(rest)
  end

  test "count pacing rotates past continuously dirty low IDs and eventually admits all" do
    desired = views(200)
    {first, packets} = EntityReplication.reconcile(EntityReplication.new(), desired)
    assert map_size(first.tracked) == 64 and length(packets) == 128
    low_ids = desired |> Map.keys() |> Enum.sort() |> Enum.take(64) |> MapSet.new()

    state =
      Enum.reduce(1..3, first, fn tick, state ->
        dirty =
          Map.new(desired, fn {id, view} ->
            revision = if MapSet.member?(low_ids, id), do: tick + 1, else: 1
            {id, %{view | revision: revision, metadata_revision: revision}}
          end)

        {next, packets} = EntityReplication.reconcile(state, dirty)
        assert length(packets) <= 128
        next
      end)

    assert map_size(state.tracked) == 200

    clean =
      Map.new(desired, fn {id, view} ->
        {_, {metadata_revision, motion_revision}} = state.tracked[id]
        {id, %{view | metadata_revision: metadata_revision, motion_revision: motion_revision}}
      end)

    assert {^state, []} = EntityReplication.reconcile(state, clean)
  end

  test "byte pacing shares large binary views without retaining a pending packet queue" do
    stack = %{
      ItemStack.new("stone")
      | components: %{
          "minecraft:custom_data" =>
            {:compound, %{"data" => {:byte_array, :binary.copy(<<1>>, 60_000)}}}
        }
    }

    desired = views(8, stack)
    {first, packets} = EntityReplication.reconcile(EntityReplication.new(), desired)
    assert map_size(first.tracked) == 4
    assert Enum.reduce(packets, 0, &(Items.packet_bytes(&1) + &2)) <= 262_144

    assert Enum.all?(first.tracked, fn {_, {epoch, revisions}} ->
             is_reference(epoch) and revisions == {1, 1}
           end)

    {next, packets} = EntityReplication.reconcile(first, desired)
    assert map_size(next.tracked) == 8
    assert Enum.reduce(packets, 0, &(Items.packet_bytes(&1) + &2)) <= 262_144
    assert {^next, []} = EntityReplication.reconcile(next, desired)
  end

  test "the maximum visible population is paced and its removals fit one bounded batch" do
    desired = Enum.reduce(1..4, %{}, fn _, acc -> Map.merge(acc, views(256)) end)
    assert map_size(desired) == 1024

    state =
      Enum.reduce(1..16, EntityReplication.new(), fn _, state ->
        {next, packets} = EntityReplication.reconcile(state, desired)
        assert length(packets) == 128
        assert map_size(next.tracked) <= 1024
        next
      end)

    assert map_size(state.tracked) == 1024
    {cleared, [packet]} = EntityReplication.reconcile(state, %{})
    assert cleared.tracked == %{}
    assert Items.packet_bytes(packet) < 262_144
    assert {1024, _} = Wire.take_varint(elem(packet, 1))
  end
end
