defmodule Valimc.Physics.LandingBlocks do
  @moduledoc "Immutable native landing damage calls; geometry and health remain player-owned."
  @path Path.expand("../../../priv/physics/landing_blocks.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count @facts["state_count"]
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @count == Valimc.Protocol.Data.block_state_count(),
         do: raise("Wrong landing block catalog version")

  @properties Enum.map(@facts["properties"], fn pair ->
                unless length(pair) == 2, do: raise("Invalid landing rule pair")

                Enum.map(pair, fn
                  :null ->
                    nil

                  rule ->
                    unless map_size(rule) == 4 and rule["distance_scale"] in [0.5, 1.0] and
                             rule["distance_offset"] in [0.0, 2.5] and
                             is_number(rule["multiplier"]) and rule["multiplier"] >= 0 and
                             rule["multiplier"] <= 2 and rule["source"] in ["fall", "stalagmite"],
                           do: raise("Invalid landing damage rule")

                    %{
                      distance_scale: rule["distance_scale"],
                      distance_offset: rule["distance_offset"],
                      multiplier: rule["multiplier"],
                      source: if(rule["source"] == "fall", do: :fall, else: :stalagmite)
                    }
                end)
                |> List.to_tuple()
              end)
              |> List.to_tuple()
  @states Base.decode16!(@facts["states"], case: :lower)
  unless tuple_size(@properties) == 6 and byte_size(@states) == @count and
           Enum.all?(:binary.bin_to_list(@states), &(&1 < tuple_size(@properties))),
         do: raise("Incomplete landing block catalog")

  def state_count, do: @count

  @doc "Observe the native block callback, including blocks that emit no damage call."
  def call(id, distance, shift)
      when is_integer(id) and id >= 0 and id < @count and is_number(distance) and
             distance >= 0 and distance <= 60_000_000 and is_boolean(shift) do
    rule = @properties |> elem(:binary.at(@states, id)) |> elem(if(shift, do: 1, else: 0))

    {:ok,
     if rule do
       %{
         distance: distance * rule.distance_scale + rule.distance_offset,
         multiplier: rule.multiplier,
         source: rule.source
       }
     end}
  end

  def call(_, _, _), do: {:error, :invalid_landing}
end
