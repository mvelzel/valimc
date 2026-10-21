defmodule Valimc.World.Light do
  @moduledoc """
  Vanilla light (VMC-022). The facts come from `LightFactsOracle`
  (`priv/physics/light_blocks.json`: emission and dampening per state, face
  occlusion classes and tables) and the vertical sky-source facts
  (`Valimc.Physics.SkyBlocks`); the engine is `valimc_core::light`.
  """
  alias Valimc.Native
  alias Valimc.Physics.SkyBlocks

  @path Path.expand("../../../priv/physics/light_blocks.json", __DIR__)
  @external_resource @path
  @facts JSON.decode!(File.read!(@path))
  unless Valimc.Version.stamped?(@facts) and
           @facts["state_count"] == Valimc.Registry.Blocks.state_count() and
           length(@facts["faces"]) == 6 and length(@facts["occludes"]) == 6,
         do: raise("Wrong light facts")

  @properties Base.decode16!(@facts["properties"], case: :lower)
  @faces Enum.map(@facts["faces"], &Base.decode16!(&1["states"], case: :lower))
  @sizes Enum.map(@facts["faces"], & &1["class_count"])
  @occludes Enum.map(@facts["occludes"], &Base.decode16!(&1["bits"], case: :lower))

  @doc "Install the light facts in the NIF; call once at application start."
  def init! do
    {sky, sky_size, sky_pairs} = SkyBlocks.facts()

    case Native.light_facts_init(@properties, @faces, @sizes, @occludes, sky, sky_size, sky_pairs) do
      :ok -> :ok
      other -> raise "light fact initialization failed: #{inspect(other)}"
    end
  end

  @doc "A state's light emission (0..15)."
  def emission(state), do: Bitwise.bsr(:binary.at(@properties, state), 4)

  @doc "A state's light dampening (0..15)."
  def dampening(state), do: Bitwise.band(:binary.at(@properties, state), 15)
end
