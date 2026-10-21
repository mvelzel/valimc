defmodule Valimc.Physics.BlockHazards do
  @moduledoc "Native player hazard requests from observed block state and movement; no geometry, health or immunity."
  alias Valimc.Registry.BlockFacts
  @threshold 0.003000000026077032

  def request(state, careful, client_authoritative, known_movement, previous_movement)
      when is_integer(state) and is_boolean(careful) and
             is_boolean(client_authoritative) do
    if vector?(known_movement) and vector?(previous_movement) do
      movement = if client_authoritative, do: known_movement, else: previous_movement
      {:ok, request(BlockFacts.hazard(state), careful, movement)}
    else
      {:error, :invalid_hazard_context}
    end
  end

  def request(_, _, _, _, _), do: {:error, :invalid_hazard_context}

  defp request({:magma, _}, false, _), do: {:hot_floor, 1.0}
  defp request({:campfire, amount}, _, _) when amount > 0, do: {:campfire, amount * 1.0}
  defp request({:cactus, _}, _, _), do: {:cactus, 1.0}

  defp request({:berry, age}, _, {x, _, z}) when age > 0 do
    if abs(x) >= @threshold or abs(z) >= @threshold, do: {:sweet_berry_bush, 1.0}
  end

  defp request(_, _, _), do: nil

  defp vector?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))
  defp vector?(_), do: false
end
