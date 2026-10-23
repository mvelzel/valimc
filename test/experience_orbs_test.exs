defmodule Valimc.ExperienceOrbsTest do
  @moduledoc "Orbs in a store (VMC-034n4c): new orbs scatter, lying orbs merge when they scan."
  use ExUnit.Case, async: true
  alias Valimc.Entity.{ExperienceOrbs, Store}

  defp orb(id, value, at, age),
    do:
      %{kind: :orb, entity_id: id, uuid: <<id::128>>, value: value, count: 1, age: age}
      |> Map.merge(at)

  test "an award spawns moving orbs, joining one only by chance" do
    orbs = ExperienceOrbs.orbs({0.5, 64.5, 0.5}, [3, 3, 1])
    assert Enum.sum(for o <- orbs, do: o.value * o.count) == 7
    assert Enum.all?(orbs, &(&1.motion.velocity != {0.0, 0.0, 0.0}))
    # The second 3 joins the first only for a pick congruent to the first's id.
    assert ExperienceOrbs.plan([3, 3], fn -> 0 end, 40) == [{3, 2}]
    assert ExperienceOrbs.plan([3, 3], fn -> 1 end, 40) == [{3, 1}, {3, 1}]
  end

  test "an orb absorbs congruent orbs of its value on its first tick and every twentieth" do
    base = 4000

    records = [
      orb(base, 3, %{x: 0.5, y: 64.0, z: 0.5}, 100),
      orb(base + 40, 3, %{x: 1.25, y: 64.0, z: 0.5}, 50),
      # Not congruent, another value, out of reach.
      orb(base + 1, 3, %{x: 0.5, y: 64.0, z: 0.75}, 0),
      orb(base + 80, 7, %{x: 0.5, y: 64.0, z: 0.5}, 0),
      orb(base + 120, 3, %{x: 1.5, y: 64.0, z: 0.5}, 0)
    ]

    store =
      Enum.reduce(records, Store.new(), fn r, acc ->
        {:ok, next, _} = Store.create_record(acc, {0, 0}, r)
        next
      end)

    {merged, removed} = Store.age(store, 1)
    absorbed = base + 40
    assert [{_, ^absorbed, _}] = removed
    assert %{count: 2, age: 51} = merged.entries[base]
    assert merged.views[base].count == 2

    # Moved together again, they wait for the next scan, nineteen ticks on.
    {:ok, store} =
      Store.remove(merged, merged.epoch, base + 40, merged.entries[base + 40].revision)

    {store, []} = Store.age(store, 18)
    store = put_in(store.entries[base + 120].entity.x, 1.0)
    {store, []} = Store.age(store, 1)
    far = base + 120
    assert {_, [{_, ^far, _}]} = Store.age(store, 1)
  end
end
