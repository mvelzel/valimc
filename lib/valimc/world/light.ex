defmodule Valimc.World.Light do
  @moduledoc """
  Vanilla light (VMC-022). The facts are the block fact table's light columns
  (emission and dampening per state, face occlusion classes and tables, and
  vertical sky-source classes); the engine is `valimc_core::light`.
  """
  alias Valimc.Native
  alias Valimc.Registry.BlockFacts

  @doc "Install the light facts in the NIF; call once at application start."
  def init! do
    %{
      properties: properties,
      faces: faces,
      sizes: sizes,
      occludes: occludes,
      sky: {sky, sky_size, sky_pairs}
    } =
      BlockFacts.light_columns()

    case Native.light_facts_init(properties, faces, sizes, occludes, sky, sky_size, sky_pairs) do
      :ok -> :ok
      other -> raise "light fact initialization failed: #{inspect(other)}"
    end
  end
end
