defmodule Valimc.EntityViewsTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.Publication
  alias Valimc.World.EntityViews

  setup do
    table = :ets.new(:views, [:set, :public])
    epoch = make_ref()
    :ok = Publication.init(table, epoch)
    route = fn _ -> {self(), nil, %{publication: table}} end
    %{table: table, epoch: epoch, route: route}
  end

  # The rows of `views` in every chunk it or `previous` holds, as a tracking
  # pass rewrites changed chunks.
  defp publish(table, epoch, tick, views, previous \\ %{}, frame \\ <<>>) do
    chunks = for {_, v} <- Map.to_list(previous) ++ Map.to_list(views), uniq: true, do: v.chunk

    rows =
      Map.new(chunks, fn chunk ->
        {chunk,
         for({id, v} <- views, v.chunk == chunk, into: %{}, do: {id, Map.put(v, :tick, tick)})}
      end)

    Publication.publish(table, epoch, tick, %{rows: rows, sources: [], frame: frame})
  end

  test "unchanged sections reuse visibility, including an entirely empty view", c do
    publish(c.table, c.epoch, 1, %{})
    regions = [{:overworld, 0, 0}]
    chunks = for x <- 0..7, z <- 0..7, do: {x, z}
    assert {%{}, cache} = EntityViews.read(regions, chunks, %{}, c.route)
    assert {%{}, ^cache} = EntityViews.read(regions, chunks, cache, c.route)
    publish(c.table, c.epoch, 2, %{1 => view(1, {0, 0})})
    assert {%{1 => _}, _} = EntityViews.read(regions, chunks, cache, c.route)
  end

  test "removal, view movement and table replacement invalidate cached observations", c do
    regions = [{:overworld, 0, 0}]
    views = %{1 => view(1, {0, 0}), 2 => view(2, {1, 0})}
    publish(c.table, c.epoch, 1, views)
    assert {%{1 => _}, cache} = EntityViews.read(regions, [{0, 0}], %{}, c.route)
    assert {%{2 => _}, moved} = EntityViews.read(regions, [{1, 0}], cache, c.route)
    publish(c.table, c.epoch, 2, %{1 => views[1]}, views)
    assert {%{}, _} = EntityViews.read(regions, [{1, 0}], moved, c.route)
    replacement = :ets.new(:replacement, [:set, :public])
    epoch = make_ref()
    :ok = Publication.init(replacement, epoch)
    publish(replacement, epoch, 1, %{3 => view(3, {0, 0})})
    route = fn _ -> {self(), nil, %{publication: replacement}} end
    assert {%{3 => _}, _} = EntityViews.read(regions, [{0, 0}], cache, route)
    :ets.delete(replacement)
    assert {%{}, _} = EntityViews.read(regions, [{0, 0}], cache, route)
  end

  test "chunk/id order and the visible limit remain deterministic", c do
    views = Map.new(1..1100, &{&1, view(&1, {rem(&1, 2), 0})})
    publish(c.table, c.epoch, 1, views)
    {got, _} = EntityViews.read([{:overworld, 0, 0}], [{1, 0}, {0, 0}], %{}, c.route)

    expected =
      views |> Enum.sort_by(fn {id, v} -> {v.chunk, id} end) |> Enum.take(1024) |> Map.new()

    assert Map.keys(got) |> Enum.sort() == Map.keys(expected) |> Enum.sort()
  end

  test "a pass rewrites only its changed rows; frames are binaries of entries", c do
    views = %{1 => view(1, {0, 0}), 2 => view(2, {1, 0})}
    publish(c.table, c.epoch, 1, views)
    stamp = :ets.lookup_element(c.table, {:entities, {1, 0}}, 2)
    revision = Publication.revision(c.table)
    frame = <<1::32, 9::16, 1::32, 7>>
    :ok = Publication.publish(c.table, c.epoch, 2, %{rows: %{}, sources: [], frame: frame})
    assert Publication.revision(c.table) == revision
    assert Publication.frames(c.table, 1) == {:ok, 2, [{2, frame}]}
    next = %{1 => %{views[1] | chunk: {2, 0}}}
    publish(c.table, c.epoch, 3, next, %{1 => views[1]})
    assert :ets.lookup(c.table, {:entities, {0, 0}}) == []
    assert :ets.lookup_element(c.table, {:entities, {1, 0}}, 2) == stamp
    refute Publication.revision(c.table) == revision
  end

  test "candidate chunk caching invalidates on movement, range and sent chunks" do
    alias Valimc.Session.Replication
    state = %{view: {{0, 0}, 32}, chunks: MapSet.new([{0, 0}, {1, 0}]), player: %{x: 0.5, z: 0.5}}
    {chunks, cached} = Replication.cached_entity_chunks(state, 32)
    assert {^chunks, ^cached} = Replication.cached_entity_chunks(cached, 32)

    for changed <- [
          put_in(cached.player.x, 100.0),
          %{cached | chunks: MapSet.new()},
          %{cached | view: {{0, 0}, 2}}
        ] do
      assert {got, _} = Replication.cached_entity_chunks(changed, 32)
      assert got == Replication.entity_chunks(changed, 32)
    end

    assert {got, _} = Replication.cached_entity_chunks(cached, 1)
    assert got == Replication.entity_chunks(cached, 1)
  end

  defp view(id, chunk),
    do: %{entity_id: id, kind: :mob, chunk: chunk, ownership_generation: 0}
end
