defmodule Valimc.Worldgen do
  @moduledoc """
  Vanilla world generation (VMC-023). The generated facts in `priv/worldgen`
  (noise parameters, density functions, noise settings and biome parameter
  presets, from `WorldgenFactsOracle`) parse once per VM into a native
  registry; `new/2` gives one seed's noises and compiled density functions for
  a noise settings entry (`valimc_core::worldgen`).
  """
  alias Valimc.Native
  alias Valimc.Registry.Blocks

  @facts ~w(noises density_functions noise_settings biome_parameters)

  @doc "The native worldgen registry, parsed from the facts on first use."
  def registry do
    case :persistent_term.get({__MODULE__, :registry}, nil) do
      nil ->
        facts =
          Enum.map(@facts, fn name ->
            Application.app_dir(:valimc, "priv/worldgen/#{name}.json")
            |> File.read!()
            |> JSON.decode!()
          end)

        [noises, functions, settings, biomes] = facts

        settings =
          Map.new(settings, fn {id, entry} ->
            {id,
             %{
               entry
               | "default_block" => state_id(entry["default_block"]),
                 "default_fluid" => state_id(entry["default_fluid"])
             }}
          end)

        fluids = Map.new(~w(air water lava), &{&1, Blocks.default_state(&1)})
        {:ok, registry} = Native.worldgen_registry(noises, functions, settings, biomes, fluids)
        :persistent_term.put({__MODULE__, :registry}, registry)
        registry

      registry ->
        registry
    end
  end

  # A block state as vanilla's codec encodes it: a name, or a name with
  # properties.
  defp state_id("minecraft:" <> name), do: Blocks.default_state(name)

  defp state_id(%{"Name" => "minecraft:" <> name} = state),
    do: Blocks.state(name, Map.get(state, "Properties", %{}))

  @doc "Worldgen state for `seed` and a noise settings entry."
  def new(seed, settings \\ "minecraft:overworld"),
    do: Native.worldgen_new(registry(), seed, settings)
end
