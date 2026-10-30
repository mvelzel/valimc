defmodule Valimc.Session.ViewWants do
  @moduledoc """
  The chunks a player's tickets want, per section (VMC-077e1, VMC-081k): a
  section's loading chunks are its chunks in the view, the simulation square
  (Chebyshev, the simulation distance) or the dragon arena, its simulated
  chunks those in the square or the arena.

  Each set depends only on the view, the square, the arena and the section, so
  a change of them visits only the chunks it moved in or out of one of them
  (`ChunkView.difference/2`, `ChunkView.square_difference/2`): a step across
  a chunk at view distance 32 visits about two hundred chunks, not the 4,225
  of the view. A change of dimension starts over.
  """
  alias Valimc.Data.Grid
  alias Valimc.Player.ChunkView

  # `basis`: `{dimension, view, square, arena}` the sets were made for;
  # `sections`: `{sx, sz} => {loading, simulated}`, non-empty MapSets.
  defstruct basis: nil, sections: %{}

  @doc """
  The wants for `view`, the square `{center, reach}` and the `arena` chunks in
  `dimension`, from those of the previous basis.
  """
  def update(%__MODULE__{} = wants, dimension, view, square, arena) do
    arena = MapSet.new(arena)
    basis = {dimension, view, square, arena}

    case wants.basis do
      ^basis ->
        wants

      {^dimension, old_view, old_square, old_arena} ->
        moved(wants.sections, basis, old_view, old_square, old_arena)

      _ ->
        moved(%{}, basis, nil, nil, MapSet.new())
    end
  end

  defp moved(sections, {_, view, square, arena} = basis, old_view, old_square, old_arena) do
    {view_in, view_out} = ChunkView.difference(old_view, view)
    {square_in, square_out} = ChunkView.square_difference(old_square, square)

    changed = [
      view_in,
      view_out,
      square_in,
      square_out,
      MapSet.to_list(MapSet.symmetric_difference(old_arena, arena))
    ]

    {sections, touched} =
      Enum.reduce(changed, {sections, %{}}, fn chunks, acc ->
        Enum.reduce(chunks, acc, fn chunk, {sections, touched} ->
          key = Grid.region_key(chunk)
          simulated = in_square?(square, chunk) or MapSet.member?(arena, chunk)
          loading = simulated or ChunkView.contains?(view, chunk)
          {l, s} = Map.get(sections, key, {MapSet.new(), MapSet.new()})
          entry = {mark(l, chunk, loading), mark(s, chunk, simulated)}
          {Map.put(sections, key, entry), Map.put(touched, key, true)}
        end)
      end)

    sections =
      Enum.reduce(touched, sections, fn {key, _}, acc ->
        {loading, _} = Map.fetch!(acc, key)
        if MapSet.size(loading) == 0, do: Map.delete(acc, key), else: acc
      end)

    %__MODULE__{basis: basis, sections: sections}
  end

  defp mark(set, chunk, true), do: MapSet.put(set, chunk)
  defp mark(set, chunk, false), do: MapSet.delete(set, chunk)

  defp in_square?(nil, _chunk), do: false

  defp in_square?({{cx, cz}, r}, {x, z}), do: abs(x - cx) <= r and abs(z - cz) <= r
end
