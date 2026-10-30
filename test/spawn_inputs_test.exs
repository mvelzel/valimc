defmodule Valimc.SpawnInputsTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.{Body, Store}
  alias Valimc.World.SpawnInputs

  test "an owner's rows follow motion, counters, persistence and simulation tickets" do
    {:ok, body} = Body.new("minecraft:cow")

    {:ok, store, {_, id, _}} =
      Store.create_record(
        Store.new(),
        {0, 0},
        Store.body_record(body, <<1::128>>, {1.5, 64.0, 0.5})
      )

    simulated = MapSet.new([{0, 0}])
    {[row], [box]} = SpawnInputs.rows(store.entries, simulated)
    assert {^id, _, {1.5, 64.0, 0.5}, 2, 0, 0} = row
    {x0, 64.0, _, x1, _, _} = box
    assert x0 < 1.5 and x1 > 1.5
    {:ok, moved, _} = Store.step_body(store, {0, 0}, id, 1, {20.5, 64.0, 0.5}, body)
    moved = update_in(moved.entries[id], &Map.merge(&1, %{idle: 10, lived: 20}))
    # Out of the simulated chunk: not checked for despawning.
    assert {[{^id, _, {20.5, 64.0, 0.5}, 0, 10, 20}], _} =
             SpawnInputs.rows(moved.entries, simulated)

    assert {[{_, _, _, 2, _, _}], _} = SpawnInputs.rows(moved.entries, MapSet.new([{1, 0}]))
    named = update_in(moved.entries[id].body, &Body.name(&1, {:string, "Kept"}))
    assert {[{_, _, _, 1, _, _}], _} = SpawnInputs.rows(named.entries, MapSet.new())
    assert {[], []} = SpawnInputs.rows(%{}, simulated)
  end
end
