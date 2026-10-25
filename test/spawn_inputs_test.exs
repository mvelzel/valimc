defmodule Valimc.SpawnInputsTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.World.SpawnInputs

  test "cached rows refresh for motion, counters, persistence and simulation tickets" do
    {:ok, body} = Body.new("minecraft:cow")

    {:ok, store, {_, id, _}} =
      Store.create_record(
        Store.new(),
        {0, 0},
        Store.body_record(body, <<1::128>>, {1.5, 64.0, 0.5})
      )

    section = %{entities: %{store: store}, tickets: %{simulated: MapSet.new([{0, 0}])}}
    sections = %{{0, 0} => section}
    {mobs, bodies, chunks, owners, cache} = SpawnInputs.prepare(sections)
    assert [{^id, _, {1.5, 64.0, 0.5}, 2, 0, 0}] = mobs
    assert chunks == [{0, 0}] and owners == %{id => {0, 0}}
    assert {^mobs, ^bodies, ^chunks, ^owners, ^cache} = SpawnInputs.prepare(sections, cache)
    {:ok, moved, _} = Store.step_body(store, {0, 0}, id, 1, {20.5, 64.0, 0.5}, body)
    moved = update_in(moved.entries[id], &Map.merge(&1, %{idle: 10, lived: 20}))
    section = put_in(section.entities.store, moved)
    {[row], _, _, _, refreshed} = SpawnInputs.prepare(%{{0, 0} => section}, cache)
    assert {^id, _, {20.5, 64.0, 0.5}, 0, 10, 20} = row
    section = put_in(section.tickets.simulated, MapSet.new([{1, 0}]))
    {[row], _, _, _, _} = SpawnInputs.prepare(%{{0, 0} => section}, refreshed)
    assert elem(row, 3) == 2
    assert {[], [], [], %{}, %{}} = SpawnInputs.prepare(%{}, cache)
  end

  test "discard/reset routing keeps result order without scanning every section per id" do
    owners = %{1 => :a, 2 => :b, 3 => :a}
    plan = SpawnInputs.distribute(%{}, [3, 2, 1], owners, 1)
    assert plan == %{a: {[], [1, 3], [], []}, b: {[], [2], [], []}}
    assert SpawnInputs.distribute(plan, [3], owners, 2).a == {[], [1, 3], [3], []}
  end
end
