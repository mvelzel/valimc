defmodule Valimc.Physics.ClimbContact do
  @moduledoc "Native climbing selection from fenced feet/below states; observations are not authority."
  alias Valimc.Physics.BlockCollisions.Frame
  alias Valimc.Registry.BlockFacts

  def sample(%Frame{states: states} = frame, {x, y, z} = pos, flying, spectator, gliding)
      when is_map(states) and map_size(states) <= 2048 and is_integer(x) and is_integer(y) and
             is_integer(z) and is_boolean(flying) and is_boolean(spectator) and
             is_boolean(gliding) do
    if flying or spectator do
      {:ok, %{climbing: false, scaffolding: false}}
    else
      with {:ok, facts} <- at(frame, pos),
           {:ok, climbing} <- climbing?(frame, pos, facts, gliding),
           do: {:ok, %{climbing: climbing, scaffolding: facts.scaffolding}}
    end
  end

  def sample(_, _, _, _, _), do: {:error, :invalid_climb_frame}

  defp climbing?(_, _, %{glide_through: true}, true), do: {:ok, false}
  defp climbing?(_, _, %{climbable: true}, _), do: {:ok, true}

  defp climbing?(frame, {x, y, z}, %{trapdoor_open: true, trapdoor_facing: direction}, _)
       when direction in 2..5 do
    with {:ok, below} <- at(frame, {x, y - 1, z}), do: {:ok, below.ladder_facing == direction}
  end

  defp climbing?(_, _, _, _), do: {:ok, false}

  defp at(%Frame{states: states}, pos) do
    case Map.fetch(states, pos) do
      {:ok, id} -> {:ok, BlockFacts.climb(id)}
      :error -> {:error, :incomplete_climb_frame}
    end
  end
end
