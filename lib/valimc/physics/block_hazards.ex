defmodule Valimc.Physics.BlockHazards do
  @moduledoc "Native player hazard requests from observed block state and movement; no geometry, health or immunity."
  @path Path.expand("../../../priv/physics/block_hazards.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count 35_723
  @threshold 0.003000000026077032
  @kinds %{"magma" => :magma, "campfire" => :campfire, "cactus" => :cactus, "berry" => :berry}
  @states Map.new(@facts["states"], fn [id, kind, value] ->
            unless is_integer(id) and id in 0..(@count - 1) and is_integer(value) and
                     value in 0..3 and is_map_key(@kinds, kind),
                   do: raise("Invalid hazard facts")

            {id, {Map.fetch!(@kinds, kind), value}}
          end)
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @facts["state_count"] == @count and map_size(@states) == 85,
         do: raise("Wrong or incomplete hazard facts")

  def request(state, careful, client_authoritative, known_movement, previous_movement)
      when is_integer(state) and state >= 0 and state < @count and is_boolean(careful) and
             is_boolean(client_authoritative) do
    if vector?(known_movement) and vector?(previous_movement) do
      movement = if client_authoritative, do: known_movement, else: previous_movement
      {:ok, request(Map.get(@states, state), careful, movement)}
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
