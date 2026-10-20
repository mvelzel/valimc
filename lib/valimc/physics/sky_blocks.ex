defmodule Valimc.Physics.SkyBlocks do
  @moduledoc "Pinned native vertical sky-source occlusion; this does not calculate lateral lighting."
  import Bitwise
  @path Path.expand("../../../priv/physics/sky_blocks.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count Valimc.Registry.Blocks.state_count()
  @classes @facts["class_count"]
  @states Base.decode16!(@facts["states"], case: :lower)
  @pairs Base.decode16!(@facts["pairs"], case: :lower)
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == @count and @classes in 1..256 and
           byte_size(@states) == @count and byte_size(@pairs) == div(@classes * @classes + 7, 8) and
           Enum.all?(:binary.bin_to_list(@states), &(&1 < @classes)),
         do: raise("Wrong or incomplete sky-source block facts")

  def blocked?(above, below)
      when is_integer(above) and above >= 0 and above < @count and
             is_integer(below) and below >= 0 and below < @count do
    offset = :binary.at(@states, above) * @classes + :binary.at(@states, below)
    {:ok, (:binary.at(@pairs, div(offset, 8)) &&& 1 <<< rem(offset, 8)) != 0}
  end

  def blocked?(_, _), do: {:error, :unknown_block_state}
end
