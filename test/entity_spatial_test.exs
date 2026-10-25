defmodule Valimc.EntitySpatialTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.Data.{Box, Grid}

  defp check(store) do
    types =
      for {_, %{body: body}} <- store.entries, reduce: %{} do
        counts -> Map.update(counts, body.type, 1, &(&1 + 1))
      end

    assert store.spatial.types == types
    for type <- Map.keys(types), do: assert(Store.has_type?(store, type))
    refute Store.has_type?(store, "minecraft:ender_dragon")

    for kind <- [:mob, :object, :item, :orb] do
      chunks = MapSet.new(store.views, fn {_, v} -> v.chunk end)
      actual = Store.in_chunks(store, chunks, kind) |> Map.new()
      assert actual == Map.filter(store.entries, fn {_, e} -> e.kind == kind end)

      for chunk <- chunks do
        expected =
          Map.filter(actual, fn {_, e} -> Grid.chunk_key(e.entity.x, e.entity.z) == chunk end)

        assert Map.new(Store.in_chunks(store, [chunk], kind)) == expected
      end
    end

    area = {-200.0, -100.0, -200.0, 200.0, 200.0, 200.0}

    expected =
      for {id, %{kind: :mob, body: body, entity: e} = entry} <- store.entries,
          box = Valimc.AI.Mobs.hook(body.type, :collider, [body, {e.x, e.y, e.z}], nil),
          box != nil,
          Box.intersects?(area, box),
          into: %{},
          do: {id, entry}

    assert Map.new(Store.colliders(store, area)) == expected
    store
  end

  test "membership follows creation, moves, removal, recovery and failed atomic batches" do
    store =
      Enum.reduce(1..60, Store.new(), fn n, store ->
        {:ok, body} = Body.new(if rem(n, 3) == 0, do: "minecraft:shulker", else: "minecraft:cow")

        {:ok, store, _} =
          Store.create_record(
            store,
            {0, 0},
            Store.body_record(body, <<n::128>>, {rem(n, 100) * 1.0, 64.0, 0.5})
          )

        store
      end)
      |> check()

    store =
      Enum.reduce(Enum.sort(store.entries), store, fn {id, e}, store ->
        {:ok, store, _} =
          Store.step_body(store, {0, 0}, id, e.revision, {127.5 - e.entity.x, 64.0, 32.5}, e.body)

        check(store)
      end)

    [{id, e} | _] = Enum.sort(store.entries)

    assert {:error, _} =
             Store.advance(store, {0, 0}, store.epoch, [
               %{id: id, revision: e.revision, position: {0.5, 64.0, 0.5}},
               %{id: id, revision: -1, position: {1.5, 64.0, 0.5}}
             ])

    check(store)
    {:ok, store} = Store.remove(store, store.epoch, id, e.revision)
    check(store)

    {:ok, recovered} =
      Store.restore({0, 0}, Enum.map(store.entries, fn {_, e} -> Store.record(e) end))

    check(recovered)
  end

  test "a changed shulker lid and worker-created items update live queries" do
    {:ok, body} = Body.new("minecraft:shulker")

    {:ok, store, {_, id, _}} =
      Store.create_record(
        Store.new(),
        {0, 0},
        Store.body_record(body, <<1::128>>, {16.5, 64.0, 0.5})
      )

    opened = %{body | data: %{body.data | attach_face: 5, peek: 100, peek_amount: 1.0}}
    store = Store.change_body(store, id, opened) |> check()
    area = {14.1, 64.1, 0.1, 15.9, 64.9, 0.9}
    assert [_] = Store.colliders(store, area)

    {:ok, proposed, _} =
      Store.create(store, {0, 0}, Valimc.Protocol.ItemStack.new("stone"), {1.0, 64.0, 1.0})

    {:ok, merged} = Store.merge_created(store, store, proposed)
    check(merged)
    assert [_] = Store.in_chunks(merged, [{0, 0}], :item)
  end

  test "type presence follows replacement and the last removal, including nonliving bodies" do
    {:ok, cow} = Body.new("minecraft:cow")
    {:ok, sheep} = Body.new("minecraft:sheep")
    {:ok, knot} = Body.new("minecraft:leash_knot")

    {store, ids} =
      Enum.map_reduce(1..2, Store.new(), fn n, store ->
        {:ok, store, {_, id, _}} =
          Store.create_record(store, {0, 0}, Store.body_record(cow, <<n::128>>, {0.5, 64.0, 0.5}))

        {id, store}
      end)
      |> then(fn {ids, store} -> {check(store), ids} end)

    [first, last] = ids
    store = Store.change_body(store, first, sheep)

    {:ok, store, _} =
      Store.create_record(store, {0, 0}, Store.body_record(knot, <<3::128>>, {1.5, 64.0, 0.5}))

    assert Store.has_type?(store, "minecraft:leash_knot")
    assert Store.has_type?(store, "minecraft:sheep")
    assert Store.has_type?(store, "minecraft:cow")
    assert store.spatial.types["minecraft:cow"] == 1
    {:ok, store} = Store.remove(store, store.epoch, last, store.entries[last].revision)
    refute Store.has_type?(store, "minecraft:cow")
    assert Store.has_type?(store, "minecraft:leash_knot")
    check(store)
    {:ok, restored} = Store.restore({0, 0}, Store.records(store))
    assert restored.spatial.types == store.spatial.types
  end
end
