defmodule Valimc.Physics.ClimbBlocks do
  @moduledoc "Complete pinned climb tags and scalar ladder/trapdoor facts."
  @path Path.expand("../../../priv/physics/climb_blocks.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count 35_723
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == @count,
         do: raise("Wrong climb block catalog version")

  @properties @facts["properties"]
              |> Enum.map(fn f ->
                unless map_size(f) == 6 and is_boolean(f["climbable"]) and
                         is_boolean(f["glide_through"]) and is_boolean(f["scaffolding"]) and
                         is_boolean(f["trapdoor_open"]) and f["ladder_facing"] in [-1, 2, 3, 4, 5] and
                         f["trapdoor_facing"] in [-1, 2, 3, 4, 5] and
                         (f["trapdoor_facing"] != -1 or not f["trapdoor_open"]),
                       do: raise("Invalid climb block properties")

                %{
                  climbable: f["climbable"],
                  glide_through: f["glide_through"],
                  scaffolding: f["scaffolding"],
                  ladder_facing: f["ladder_facing"],
                  trapdoor_facing: f["trapdoor_facing"],
                  trapdoor_open: f["trapdoor_open"]
                }
              end)
              |> List.to_tuple()
  @states Base.decode16!(@facts["states"], case: :lower)
  unless tuple_size(@properties) == 15 and byte_size(@states) == @count and
           Enum.all?(:binary.bin_to_list(@states), &(&1 < tuple_size(@properties))),
         do: raise("Invalid climb block indexes")

  def count, do: @count

  def fetch(id) when is_integer(id) and id >= 0 and id < @count,
    do: {:ok, elem(@properties, :binary.at(@states, id))}

  def fetch(_), do: {:error, :unknown_block_state}
end
