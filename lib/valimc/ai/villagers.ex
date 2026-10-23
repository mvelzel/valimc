defmodule Valimc.AI.Villagers do
  @moduledoc """
  What the villager family reads of vanilla beside the POI types
  (`village_facts.json`, VMC-044a1): professions in registry order with the
  job sites they hold and may acquire, their secondary POI blocks and work
  sounds; villager types and the type each biome gives; the schedule of a
  day (`villager_activity`, the same in every dimension) for adults and
  babies; and the family's sound ids.
  """
  alias Valimc.AI.Pois

  use Valimc.Data.Facts, "registry/village_facts.json"

  @professions Map.new(@facts["professions"], fn p ->
                 {p["name"],
                  %{
                    id: p["id"],
                    held: p["held"],
                    acquirable: p["acquirable"],
                    secondary: p["secondary_poi"],
                    work_sound: p["work_sound"]
                  }}
               end)
  @profession_order @facts["professions"] |> Enum.sort_by(& &1["id"]) |> Enum.map(& &1["name"])
  @types Map.new(@facts["villager_types"], &{&1["name"], &1["id"]})
  @by_biome @facts["villager_type_by_biome"]
  @sounds @facts["sounds"]

  schedules = Map.values(@facts["schedules"])

  unless Enum.uniq(schedules) |> length() == 1,
    do: raise("villager schedules differ between dimensions")

  [schedule] = Enum.uniq(schedules)

  runs = fn key ->
    for [from, activity] <- schedule[key], do: {from, String.to_atom(activity)}
  end

  @adult runs.("adult")
  @baby runs.("baby")

  @doc "The POI types as the facts give them (`Valimc.AI.Pois` reads them)."
  def poi_facts, do: @facts["poi_types"]

  @doc "The profession named `name`."
  def profession(name), do: Map.fetch!(@professions, name)

  @doc "The profession names in registry order."
  def professions, do: @profession_order

  @doc "The protocol id of profession `name`."
  def profession_id(name), do: profession(name).id

  @doc "The protocol id of villager type `name`."
  def type_id(name), do: Map.fetch!(@types, name)

  @doc "Whether `name` is a villager type."
  def type?(name), do: Map.has_key?(@types, name)

  @doc "Whether `name` is a profession."
  def profession?(name), do: Map.has_key?(@professions, name)

  @doc "`VillagerType.byBiome` (plains for a biome none names)."
  def type_of_biome(biome), do: Map.get(@by_biome, biome, "minecraft:plains")

  @doc "Whether profession `name` holds a job site of POI type `poi` (`heldJobSite`)."
  def holds?(name, poi), do: poi in profession(name).held

  @doc "Whether profession `name` may acquire a job site of POI type `poi`."
  def acquires?(name, poi), do: poi in profession(name).acquirable

  @doc "The POI types any profession may acquire (`ALL_ACQUIRABLE_JOBS`)."
  def acquirable_jobs,
    do: Enum.filter(Pois.types(), &Pois.tagged?(&1, "minecraft:acquirable_job_site"))

  @doc "The first profession in registry order holding a job site of `poi`."
  def profession_for(poi), do: Enum.find(@profession_order, &holds?(&1, poi))

  @doc "The activity the schedule gives at day tick `ticks` (`baby` for a baby's)."
  def scheduled(ticks, baby) do
    t = Integer.mod(ticks, 24_000)
    runs = if baby, do: @baby, else: @adult

    {_, activity} = runs |> Enum.take_while(fn {from, _} -> from <= t end) |> List.last()
    activity
  end

  @doc "The sound id of `name`."
  def sound_id(name), do: Map.fetch!(@sounds, name)
end
