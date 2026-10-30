defmodule Valimc.EntityMembershipTest do
  use ExUnit.Case, async: true
  alias Valimc.Entity.Observer
  alias Valimc.Session.EntityMembership
  alias Valimc.World.EntityViews

  # A view as rows publish it: in range when its x is below 40.
  defp view(id, chunk, x, generation \\ 0, tracker \\ 1) do
    %{
      entity_id: id,
      kind: :mob,
      chunk: chunk,
      at: {x, 64.0, 0.5},
      base: {x, 64.0, 0.5},
      velocity: {0.0, 0.0, 0.0},
      on_ground: true,
      ownership_generation: generation,
      epoch: :epoch,
      tracker: tracker,
      tick: 1,
      spawn: {1, <<id::32>>},
      metadata: nil
    }
  end

  defp visible(view), do: elem(view.at, 0) < 40.0

  defp rows(views, _stamp) do
    views
    |> Enum.group_by(& &1.chunk)
    |> Map.new(fn {chunk, list} ->
      {chunk, {:erlang.phash2(list), list |> Enum.map(&{&1.entity_id, &1}) |> Enum.sort()}}
    end)
  end

  defp expected(rows) do
    rows
    |> Map.new(fn {chunk, {stamp, views}} ->
      {chunk, {stamp, Enum.filter(views, fn {_, v} -> visible(v) end)}}
    end)
    |> EntityViews.select()
  end

  defp frames, do: fn _, last -> {:ok, last || 0, []} end

  test "changed rows keep the desired views and the observer as a full pass does" do
    :rand.seed(:exsss, {3, 5, 8})

    population =
      Map.new(1..60, fn id -> {id, view(id, {rem(id, 6), 0}, :rand.uniform() * 60.0)} end)

    Enum.reduce(1..300, {population, %EntityMembership{}, Observer.new(), Observer.new()}, fn
      step, {population, m, inc, full} ->
        population =
          Enum.reduce(1..:rand.uniform(6), population, fn _, acc ->
            id = :rand.uniform(80)

            case :rand.uniform(10) do
              1 -> Map.delete(acc, id)
              2 -> Map.put(acc, id, view(id, {:rand.uniform(8), 0}, 30.0, 0, step))
              # A handoff: the same entity in a second section's row.
              3 -> Map.put(acc, {:dup, id}, view(id, {9, 0}, 10.0, 1))
              _ -> Map.put(acc, id, view(id, {rem(id, 6), 0}, :rand.uniform() * 60.0))
            end
          end)

        rows = rows(Map.values(population), step)
        {m, desired, touched} = EntityMembership.update(m, rows, :key, &visible/1)
        assert desired == expected(rows), "step #{step}"
        {inc, _} = Observer.reconcile(inc, desired, touched, frames())
        {full, _} = Observer.reconcile(full, desired, :all, frames())
        assert inc.tracked == full.tracked and inc.waiting == full.waiting, "step #{step}"
        {population, m, inc, full}
    end)
  end

  test "an unchanged row set touches nothing; a new key touches every id" do
    rows = rows([view(1, {0, 0}, 1.0), view(2, {1, 0}, 50.0)], 1)
    {m, desired, :all} = EntityMembership.update(%EntityMembership{}, rows, :a, &visible/1)
    assert Map.keys(desired) == [1]
    assert {^m, ^desired, []} = EntityMembership.update(m, rows, :a, &visible/1)
    assert {_, _, :all} = EntityMembership.update(m, rows, :b, &visible/1)
  end
end
