defmodule Valimc.World.ColumnIndex do
  @moduledoc "Sparse flat-world column words; mutations update two sky edges and two height predicates."
  alias Valimc.Physics.{HeightmapBlocks, SkyBlocks}
  alias Valimc.World.{Chunk, ColumnHeight}
  @flat ColumnHeight.flat()
  @default {@flat, @flat, @flat}

  def restore(edits), do: update(%{}, edits, edits)

  @doc "The complete post-mutation edit map supplies adjacent states, including other edits in this batch."
  def update(index, edits, changes) do
    Enum.reduce(changes, index, fn
      {{_, y, _}, _}, acc when y < -64 or y > 319 ->
        acc

      {{x, y, z} = position, block}, acc ->
        key = {x, z}
        {surface, motion, sky} = Map.get(acc, key, @default)
        {:ok, opaque} = HeightmapBlocks.opaque?(block, :world_surface)
        {:ok, surface} = ColumnHeight.update(surface, y, opaque)
        {:ok, opaque} = HeightmapBlocks.opaque?(block, :motion_blocking)
        {:ok, motion} = ColumnHeight.update(motion, y, opaque)
        sky = sky_edge(sky, edits, {x, y + 1, z}, position)
        sky = if y > -64, do: sky_edge(sky, edits, position, {x, y - 1, z}), else: sky
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

  defp sky_edge(bits, edits, above, {_, y, _} = below) do
    {:ok, blocked} =
      SkyBlocks.blocked?(Chunk.block_at(edits, above), Chunk.block_at(edits, below))

    {:ok, bits} = ColumnHeight.update(bits, y, blocked)
    bits
  end
end
