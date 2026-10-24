defmodule Valimc.World.EntityColliders do
  @moduledoc "Bounded solid-entity observations for player physics, read from owner publications."
  alias Valimc.Data.{Box, Grid}
  alias Valimc.Entity.Publication
  alias Valimc.Physics.EntityCollisions
  alias Valimc.World.{Directory, View}

  @doc "Complete nearby solid boxes, including lids whose centres lie in the next chunk."
  def collect(%View{supplied: supplied}, _query, _subject) when supplied != nil, do: {:ok, []}

  def collect(%View{dimension: dimension}, query, subject) do
    # A currently supported solid entity reaches at most 1.5 blocks from
    # its centre. Two blocks include every chunk containing such a centre.
    with {:ok, _} <- EntityCollisions.collect(query, subject, []),
         {:ok, candidates} <- candidates(dimension, query),
         candidates =
           for(
             {id, {_, box}} <- Enum.sort(candidates),
             do: %{id: id, box: box, collidable: true, spectator: false, same_vehicle: false}
           ),
         {:ok, %{colliders: boxes}} <- EntityCollisions.collect(query, subject, candidates) do
      {:ok, Enum.map(boxes, & &1.box)}
    end
  end

  defp candidates(dimension, query) do
    Enum.reduce_while(chunks(query), {:ok, %{}}, fn chunk, {:ok, found} ->
      boxes =
        case table(dimension, chunk) do
          nil -> %{}
          table -> elem(Publication.colliders(table, chunk), 1)
        end

      result =
        Enum.reduce_while(boxes, {:ok, found}, fn {id, {hops, box}}, {:ok, found} ->
          found =
            if Box.intersects?(inflate(query, 1.0e-7), box) do
              Map.update(found, id, {hops, box}, fn {old_hops, _} = old ->
                if hops > old_hops, do: {hops, box}, else: old
              end)
            else
              found
            end

          if map_size(found) > 256,
            do: {:halt, {:error, :entity_query_limit}},
            else: {:cont, {:ok, found}}
        end)

      case result do
        {:ok, _} -> {:cont, result}
        {:error, _} -> {:halt, result}
      end
    end)
  end

  @doc "Nearby solid-box stamps invalidate a resting player's cached pose when a lid moves."
  def signature(player) do
    dimension = Map.get(player, :dimension, Valimc.World.Dimension.current())
    query = {player.x, player.y, player.z, player.x, player.y, player.z}

    for chunk <- chunks(query) do
      stamp =
        case table(dimension, chunk) do
          nil -> nil
          table -> Publication.collider_stamp(table, chunk)
        end

      {chunk, stamp}
    end
  end

  defp table(dimension, chunk) do
    case Directory.lookup(Grid.section(dimension, chunk)) do
      {_, _, %{publication: table}} -> table
      _ -> nil
    end
  end

  defp chunks({x0, _, z0, x1, _, z1}) do
    {cx0, cz0} = Grid.chunk_key(x0 - 2, z0 - 2)
    {cx1, cz1} = Grid.chunk_key(x1 + 2, z1 + 2)
    for cx <- cx0..cx1, cz <- cz0..cz1, do: {cx, cz}
  end

  defp inflate({x0, y0, z0, x1, y1, z1}, e), do: {x0 - e, y0 - e, z0 - e, x1 + e, y1 + e, z1 + e}
end
