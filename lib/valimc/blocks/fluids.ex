defmodule Valimc.Blocks.Fluids do
  @moduledoc """
  Water and lava (VMC-031a): the settings the Rust fluid rules
  (`valimc_core::rules::fluid`) run with, and what a bucket names. The rules
  read `priv/physics/fluids.json` themselves (`FluidOracle facts`); this
  module keeps its dimension attributes, game rule defaults and pickup items.

  Fluid ticks are scheduled ticks keyed `{:fluid, id}` (vanilla's fluid
  registry ids: 1 flowing water, 2 water, 3 flowing lava, 4 lava).
  """
  use Valimc.Data.Facts, "physics/fluids.json"
  import Bitwise

  @dimensions Map.new(@facts["dimensions"], fn {name, values} ->
                {name, {values["fast_lava"], values["water_evaporates"]}}
              end)
  @game_rules @facts["game_rules"]
  @pickup_items @facts["pickup_items"] |> Enum.with_index(1) |> Map.new(fn {n, i} -> {i, n} end)
  @fluids %{1 => :flowing_water, 2 => :water, 3 => :flowing_lava, 4 => :lava}
  @ids Map.new(@fluids, fn {id, name} -> {name, id} end)

  @doc "A source conversion game rule's default (`water_source_conversion`, `lava_source_conversion`)."
  def game_rule(name), do: Map.fetch!(@game_rules, name)

  @doc """
  The rules' settings bits for a dimension type (`minecraft:the_nether`) and
  the conversion rules: fast lava, evaporating water, water and lava source
  conversion (`Options::from_bits`).
  """
  def options(dimension_type, water_conversion, lava_conversion) do
    {fast, evaporates} = Map.fetch!(@dimensions, dimension_type)

    bit(fast, 1) ||| bit(evaporates, 2) ||| bit(water_conversion, 4) |||
      bit(lava_conversion, 8)
  end

  defp bit(true, value), do: value
  defp bit(false, _), do: 0

  @doc "Whether water poured in a dimension type evaporates."
  def evaporates?(dimension_type), do: elem(Map.fetch!(@dimensions, dimension_type), 1)

  @doc "The item a pickup's result (`live::Outcome::results`, item index + 1) names."
  def pickup_item(result), do: Map.fetch!(@pickup_items, result)

  @doc "A fluid id's name."
  def name(id), do: Map.fetch!(@fluids, id)

  @doc "A fluid's id by its registry name (`minecraft:water`)."
  def id("minecraft:" <> name), do: Map.fetch!(@ids, String.to_existing_atom(name))
end
