defmodule Valimc.Worldgen.Facts do
  @moduledoc """
  What Elixir reads of vanilla's worldgen facts (`priv/worldgen`), decoded at
  compile time: the biome names and climates and the ids of the registries
  commands name (configured features, structures, structure sets, template
  pools and templates). The native registry gets the files themselves at run
  time (`Valimc.Worldgen`), so these terms stay small.
  """
  use Valimc.Facts, "worldgen/biomes.json"
  use Valimc.Facts, file: "worldgen/features.json", as: :features
  use Valimc.Facts, file: "worldgen/structures.json", as: :structures
  use Valimc.Facts, file: "worldgen/structure_sets.json", as: :structure_sets
  use Valimc.Facts, file: "worldgen/template_pools.json", as: :pools
  use Valimc.Facts, file: "worldgen/structure_templates.json", as: :templates

  @biome_names @facts |> Map.keys() |> Enum.sort()
  @climates for name <- @biome_names,
                biome = @facts[name],
                do:
                  {name, biome["temperature"] * 1.0, biome["temperature_modifier"] == "frozen",
                   biome["has_precipitation"]}

  @doc "Biome names in the native registry's order (registry ids index this list)."
  def biome_names, do: @biome_names

  @doc """
  Each biome's climate in `biome_names/0` order: `{name, base temperature,
  frozen temperature modifier?, has precipitation?}`.
  """
  def biome_climates, do: @climates

  @doc "Configured feature ids."
  def features, do: unquote(Macro.escape(@features |> Map.keys() |> MapSet.new()))

  @doc "Structure ids."
  def structures, do: unquote(Macro.escape(@structures |> Map.keys() |> MapSet.new()))

  @doc "Structure set ids."
  def structure_sets, do: unquote(Macro.escape(@structure_sets |> Map.keys() |> MapSet.new()))

  @doc "Template pool ids."
  def template_pools, do: unquote(Macro.escape(@pools |> Map.keys() |> MapSet.new()))

  @doc "Structure template ids, sorted."
  def templates, do: unquote(@templates |> Map.keys() |> Enum.sort())
end
