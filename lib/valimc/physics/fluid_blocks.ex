defmodule Valimc.Physics.FluidBlocks do
  @moduledoc "Complete pinned scalar fluid facts; surface/flow observations remain contextual."
  @path Path.expand("../../../priv/physics/fluid_blocks.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  @count Valimc.Registry.Blocks.state_count()
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == @count,
         do: raise("Wrong fluid block catalog version")

  @properties Enum.map(@facts["properties"], fn f ->
                unless map_size(f) == 5 and f["kind"] in 0..2 and
                         is_integer(f["amount"]) and f["amount"] in 0..8 and
                         is_float(f["height"]) and f["height"] >= 0 and f["height"] <= 1 and
                         is_boolean(f["source"]) and is_boolean(f["falling"]),
                       do: raise("Invalid fluid properties")

                %{
                  kind: elem({:empty, :water, :lava}, f["kind"]),
                  amount: f["amount"],
                  height: f["height"],
                  source: f["source"],
                  falling: f["falling"]
                }
              end)
              |> List.to_tuple()
  @states Base.decode16!(@facts["states"], case: :lower)
  @replacements @facts["replacement_states"] |> List.to_tuple()
  unless tuple_size(@properties) == 20 and byte_size(@states) == @count and
           tuple_size(@replacements) == tuple_size(@properties) and
           Enum.all?(Tuple.to_list(@replacements), &(is_integer(&1) and &1 in 0..(@count - 1))) and
           Enum.all?(:binary.bin_to_list(@states), &(&1 < tuple_size(@properties))),
         do: raise("Invalid fluid block indexes")

  def count, do: @count

  def fetch(id) when is_integer(id) and id >= 0 and id < @count,
    do: {:ok, elem(@properties, :binary.at(@states, id))}

  def fetch(_), do: {:error, :unknown_block_state}

  @doc "Native base block removal retains its contained fluid; block-specific callbacks are separate."
  def after_removal(id) when is_integer(id) and id >= 0 and id < @count,
    do: elem(@replacements, :binary.at(@states, id))
end
