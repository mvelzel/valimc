defmodule Valimc.World.ColumnIndex do
  @moduledoc "Sparse flat-world column words; mutations update two sky edges and two height predicates."
  alias Valimc.Registry.BlockFacts
  alias Valimc.World.ColumnHeight
  @flat ColumnHeight.flat()
  @default {@flat, @flat, @flat}

  @doc "Rebuild from sparse edits; `lookup` reads the complete post-edit block at a position."
  def restore(edits, lookup), do: update(%{}, lookup, edits)

  @doc "`lookup` reads post-mutation states, including other changes in this batch."
  def update(index, lookup, changes) when is_function(lookup, 1) do
    Enum.reduce(changes, index, fn
      {{_, y, _}, _}, acc when y < -64 or y > 319 ->
        acc

      {{x, y, z} = position, block}, acc ->
        key = {x, z}
        {surface, motion, sky} = Map.get(acc, key, @default)

        {:ok, surface} =
          ColumnHeight.update(surface, y, BlockFacts.heightmap?(block, :world_surface))

        {:ok, motion} =
          ColumnHeight.update(motion, y, BlockFacts.heightmap?(block, :motion_blocking))

        sky = sky_edge(sky, lookup, {x, y + 1, z}, position)
        sky = if y > -64, do: sky_edge(sky, lookup, position, {x, y - 1, z}), else: sky
        words = {surface, motion, sky}
        if words == @default, do: Map.delete(acc, key), else: Map.put(acc, key, words)
    end)
  end

  def heights(index, column) do
    {surface, motion, sky} = Map.get(index, column, @default)
    {:ok, surface} = ColumnHeight.height(surface)
    {:ok, motion} = ColumnHeight.height(motion)
    {:ok, sky} = ColumnHeight.height(sky)
    %{world_surface: surface, motion_blocking: motion, sky_source: sky}
  end

  defp sky_edge(bits, lookup, above, {_, y, _} = below) do
    {:ok, bits} =
      ColumnHeight.update(bits, y, BlockFacts.sky_blocked?(lookup.(above), lookup.(below)))

    bits
  end
end
