defmodule Valimc.Physics.StuckBlocks do
  @moduledoc "Pinned cobweb, berry bush and powder-snow class facts; other effects are separate."
  @path Path.expand("../../../priv/physics/stuck_blocks.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count 35_723
  unless @facts["version"] == "26.3" and @facts["data_version"] == 5023 and
           @facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
           @facts["state_count"] == @count and
           Enum.sort(Map.keys(@facts["states"])) == ["berry_bush", "cobweb", "powder_snow"],
         do: raise("Wrong slowing block catalog")

  @pairs for {name, kind} <- [
               {"cobweb", :cobweb},
               {"berry_bush", :berry_bush},
               {"powder_snow", :powder_snow}
             ],
             id <- @facts["states"][name],
             do: {id, kind}
  @states Map.new(@pairs)
  unless map_size(@states) == length(@pairs) and
           Enum.all?(Map.keys(@states), &(is_integer(&1) and &1 >= 0 and &1 < @count)),
         do: raise("Invalid slowing block states")

  def fetch(id) when is_integer(id) and id >= 0 and id < @count,
    do: {:ok, Map.get(@states, id, :none)}

  def fetch(_), do: {:error, :unknown_block_state}
end
