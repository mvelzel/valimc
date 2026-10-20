defmodule Valimc.Worldgen do
  @moduledoc """
  Vanilla world generation (VMC-023). The generated facts in `priv/worldgen`
  (noise parameters, density functions, noise settings and biome parameter
  presets, from `WorldgenFactsOracle`) parse once per VM into a native
  registry; `new/2` gives one seed's noises and compiled density functions for
  a noise settings entry (`valimc_core::worldgen`).
  """
  alias Valimc.Native

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

        {:ok, registry} = apply(Native, :worldgen_registry, facts)
        :persistent_term.put({__MODULE__, :registry}, registry)
        registry

      registry ->
        registry
    end
  end

  @doc "Worldgen state for `seed` and a noise settings entry."
  def new(seed, settings \\ "minecraft:overworld"),
    do: Native.worldgen_new(registry(), seed, settings)
end
