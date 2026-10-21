defmodule Valimc.World.Climate do
  @moduledoc """
  Precipitation at a block, vanilla's `Biome.getPrecipitationAt` (VMC-077e):
  none for a biome without precipitation, else snow below temperature 0.15 and
  rain above. The base temperature and `frozen` modifier come from the biome
  registry facts (`priv/worldgen/biomes.json`, the generator's own); the
  temperature at the block (frozen-ocean patches, cooling above the snow line)
  is the native `Biome.getTemperature`.
  """
  alias Valimc.Native
  alias Valimc.Protocol.Data

  @facts Valimc.Worldgen.Facts.biome_climates()
         |> Enum.map(fn {name, temperature, frozen, precipitation} ->
           {Data.registry_id("minecraft:worldgen/biome", name),
            {temperature, frozen, precipitation}}
         end)
         |> Enum.sort()
  unless Enum.map(@facts, &elem(&1, 0)) == Enum.to_list(0..(length(@facts) - 1)),
    do: raise("Biome climates do not cover the biome registry")

  @climates @facts |> Enum.map(&elem(&1, 1)) |> List.to_tuple()

  @doc "`:none`, `:rain` or `:snow` at `position` in biome `id` under a generator with `sea_level`."
  def precipitation(id, {x, y, z}, sea_level) do
    {temperature, frozen, wet} = elem(@climates, id)

    cond do
      not wet ->
        :none

      elem(Native.biome_temperature(temperature, frozen, x, y, z, sea_level), 1) < 0.15 ->
        :snow

      true ->
        :rain
    end
  end

  @doc "The native `Biome.getTemperature` at `position` in biome `id`."
  def temperature(id, {x, y, z}, sea_level) do
    {temperature, frozen, _} = elem(@climates, id)
    elem(Native.biome_temperature(temperature, frozen, x, y, z, sea_level), 1)
  end
end
