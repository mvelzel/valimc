defmodule Valimc.AI.Spatial do
  @moduledoc "A tick-local grid of sensed mob boxes, preserving the original entity order."

  def new(mobs) when length(mobs) < 32, do: nil

  def new(mobs) do
    order = mobs |> Enum.with_index() |> Map.new(fn {m, n} -> {m.uuid, n} end)

    Enum.reduce(
      mobs,
      %{cells: %{}, members: %{}, order: order, values: List.to_tuple(mobs)},
      &put(&2, &1)
    )
  end

  def put(nil, _mob), do: nil

  def put(index, mob) do
    id = Map.fetch!(index.order, mob.uuid)
    cells = cells(Valimc.AI.World.box(mob))
    old = Map.get(index.members, mob.uuid, [])

    if cells == old do
      index
    else
      grid =
        Enum.reduce(old -- cells, index.cells, fn cell, grid ->
          set = MapSet.delete(Map.fetch!(grid, cell), id)
          if MapSet.size(set) == 0, do: Map.delete(grid, cell), else: Map.put(grid, cell, set)
        end)

      grid =
        Enum.reduce(cells -- old, grid, fn cell, grid ->
          Map.update(grid, cell, MapSet.new([id]), &MapSet.put(&1, id))
        end)

      %{index | cells: grid, members: Map.put(index.members, mob.uuid, cells)}
    end
  end

  def candidates(index, box) do
    {a, b, c, d} = bounds(box)
    # Wide searches retain the linear path instead of enumerating empty space.
    if (c - a + 1) * (d - b + 1) > 128 do
      :all
    else
      for x <- a..c, z <- b..d, reduce: MapSet.new() do
        ids -> MapSet.union(ids, Map.get(index.cells, {x, z}, MapSet.new()))
      end
      |> Enum.sort()
      |> Enum.map(&elem(index.values, &1))
    end
  end

  defp cells(box) do
    {a, b, c, d} = bounds(box)
    for x <- a..c, z <- b..d, do: {x, z}
  end

  defp bounds({x0, _, z0, x1, _, z1}) do
    {a, b} = {Integer.floor_div(floor(x0), 8), Integer.floor_div(floor(z0), 8)}
    {c, d} = {Integer.floor_div(floor(x1), 8), Integer.floor_div(floor(z1), 8)}
    {a, b, c, d}
  end
end
