defmodule Valimc.Physics.InsideBlocks do
  @moduledoc "Pinned inside-block categories and static shape exceptions; powder snow uses entity context."
  @path Path.expand("../../../priv/physics/inside_blocks.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @count Valimc.Registry.Blocks.state_count()
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == @count and length(@facts["fire"]) == 512 and
           length(@facts["soul_fire"]) == 1 and length(@facts["air"]) == 3,
         do: raise("Wrong inside-block facts")

  @kinds Map.new(
           for {key, kind} <- [{"air", :air}, {"fire", :fire}, {"soul_fire", :soul_fire}],
               id <- @facts[key],
               do: {id, kind}
         )
         |> Map.put(@facts["powder_snow"], :powder_snow)
  @shapes Map.new(@facts["custom_shapes"], fn [id, boxes] ->
            boxes = Enum.map(boxes, &List.to_tuple/1)

            unless id in 0..(@count - 1) and Enum.all?(boxes, &Valimc.Physics.Box.valid?/1),
              do: raise("Invalid inside-block shape")

            {id, boxes}
          end)
          |> Map.put(@facts["powder_snow"], :powder_snow)
  unless map_size(@kinds) == 517 and map_size(@shapes) == 137,
    do: raise("Incomplete inside-block facts")

  def fetch(id) when is_integer(id) and id >= 0 and id < @count,
    do: {:ok, {Map.get(@kinds, id, :none), Map.get(@shapes, id, :full)}}

  def fetch(_), do: {:error, :unknown_block_state}
end
