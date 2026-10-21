defmodule Valimc.Physics.EntityCollisions do
  @moduledoc "Pure player collider policy over complete supplied entity observations, never live authority."
  alias Valimc.Physics.Box
  @epsilon 1.0e-7
  @max_candidates 256

  # collidable is canBeCollidedWith(subject), not a universal entity-type flag.
  def collect(box, subject, candidates) do
    with true <- query?(box) and (is_nil(subject) or identity?(subject)),
         :ok <- validate(candidates, MapSet.new(), 0) do
      if size(box) < @epsilon do
        {:ok, %{query_box: nil, colliders: []}}
      else
        query = inflate(box)

        colliders =
          for candidate <- candidates,
              candidate.id != subject,
              not candidate.spectator and candidate.collidable,
              is_nil(subject) or not candidate.same_vehicle,
              Box.intersects?(query, candidate.box),
              do: %{id: candidate.id, box: candidate.box}

        {:ok, %{query_box: query, colliders: colliders}}
      end
    else
      false -> {:error, :invalid_entity_query}
      {:error, _} = error -> error
    end
  end

  defp validate([], _, _), do: :ok

  defp validate(
         [
           %{id: id, box: box, spectator: spectator, collidable: collidable, same_vehicle: same}
           | rest
         ],
         seen,
         count
       )
       when count < @max_candidates and is_boolean(spectator) and is_boolean(collidable) and
              is_boolean(same) do
    cond do
      not identity?(id) or not Box.valid?(box) -> {:error, :invalid_entity_observations}
      MapSet.member?(seen, id) -> {:error, :duplicate_entity_observation}
      true -> validate(rest, MapSet.put(seen, id), count + 1)
    end
  end

  defp validate(_, _, _), do: {:error, :invalid_entity_observations}
  defp identity?(id), do: is_integer(id) and id in 0..2_147_483_647

  defp query?(box) do
    Box.valid?(box) and
      Enum.all?(Tuple.to_list(box), &(abs(&1) <= 59_999_999)) and
      Enum.all?(lengths(box), &(&1 <= 64))
  end

  defp size(box), do: Enum.sum(lengths(box)) / 3.0
  defp lengths({a, b, c, x, y, z}), do: [x - a, y - b, z - c]

  defp inflate({a, b, c, x, y, z}),
    do: {a - @epsilon, b - @epsilon, c - @epsilon, x + @epsilon, y + @epsilon, z + @epsilon}
end
