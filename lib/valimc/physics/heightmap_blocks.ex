defmodule Valimc.Physics.HeightmapBlocks do
  @moduledoc "Pinned native heightmap predicate masks for every block state, including resolved block tags."
  import Bitwise
  @path Path.expand("../../../priv/physics/heightmap_blocks.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count Valimc.Registry.Blocks.state_count()
  @types [
    :world_surface_wg,
    :world_surface,
    :ocean_floor_wg,
    :ocean_floor,
    :motion_blocking,
    :motion_blocking_no_leaves
  ]
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == @count and
           @facts["types"] == Enum.map(@types, &(Atom.to_string(&1) |> String.upcase())),
         do: raise("Wrong heightmap block facts")

  @masks List.to_tuple(@facts["flags"])
  @states Base.decode16!(@facts["states"], case: :lower)
  @bits Map.new(Enum.with_index(@types), fn {type, index} -> {type, 1 <<< index} end)
  unless byte_size(@states) == div(@count + 1, 2) and tuple_size(@masks) in 1..16 and
           Enum.all?(Tuple.to_list(@masks), &(is_integer(&1) and &1 in 0..63)) and
           Enum.all?(0..(@count - 1), fn id ->
             byte = :binary.at(@states, div(id, 2))
             index = if rem(id, 2) == 0, do: byte >>> 4, else: byte &&& 15
             index < tuple_size(@masks)
           end) and (:binary.last(@states) &&& 15) == 0,
         do: raise("Incomplete heightmap block facts")

  def mask(id) when is_integer(id) and id >= 0 and id < @count do
    byte = :binary.at(@states, div(id, 2))
    index = if rem(id, 2) == 0, do: byte >>> 4, else: byte &&& 15
    {:ok, elem(@masks, index)}
  end

  def mask(_), do: {:error, :unknown_block_state}

  def opaque?(id, type) when is_map_key(@bits, type) do
    with {:ok, mask} <- mask(id), do: {:ok, (mask &&& Map.fetch!(@bits, type)) != 0}
  end

  def opaque?(_, _), do: {:error, :unknown_heightmap_type}
end
