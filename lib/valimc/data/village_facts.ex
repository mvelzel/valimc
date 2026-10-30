defmodule Valimc.Data.VillageFacts do
  @moduledoc """
  What the Elixir side reads of the village's facts (`village_facts.json`,
  `VillageOracle facts`, VMC-044a1): the POI types with their block states,
  tickets and tags, and the villager types and professions by name. Native
  villagers read the whole file (`Valimc.Entity.MobFacts`).
  """
  use Valimc.Data.Facts, "registry/village_facts.json"

  @pois Map.new(@facts["poi_types"], fn {name, t} ->
          {name, %{states: t["states"], max_tickets: t["max_tickets"], tags: t["tags"]}}
        end)
  @professions MapSet.new(@facts["professions"], & &1["name"])
  @types MapSet.new(@facts["villager_types"], & &1["name"])

  @doc "The POI types by name: `%{states, max_tickets, tags}`."
  def pois, do: @pois

  @doc "Whether `name` is a villager type."
  def type?(name), do: MapSet.member?(@types, name)

  @doc "Whether `name` is a profession."
  def profession?(name), do: MapSet.member?(@professions, name)
end
