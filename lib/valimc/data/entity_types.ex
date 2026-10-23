defmodule Valimc.Data.EntityTypes do
  @moduledoc """
  Every 26.3 entity type's facts and the entity data fields, from one generated
  table (`priv/registry/entity_facts.json`, `EntityOracle facts`, VMC-043a):
  registry id, category, size and eye height, default attributes (living
  types), fire immunity, loot table, spawn placement and heightmap, whether it
  is saved, summonable, allowed in peaceful and spawned far from players, and its tracking range, update
  interval and whether its motion is tracked.
  """
  use Valimc.Data.Facts, "registry/entity_facts.json"
  use Valimc.Data.Facts, file: "protocol/tags.json", as: :tags

  @types Map.new(@facts["types"], fn {name, type} ->
           {name,
            %{
              id: type["id"],
              category: String.to_atom(type["category"]),
              width: type["width"],
              height: type["height"],
              eye_height: type["eye_height"],
              fire_immune: type["fire_immune"],
              summonable: type["summonable"],
              saved: type["saved"],
              peaceful: type["peaceful"],
              spawn_far: type["spawn_far"],
              tracking_range: type["tracking_range"],
              update_interval: type["update_interval"],
              track_deltas: type["track_deltas"],
              description: type["description"],
              loot_table: type["loot_table"],
              spawn_placement: type["spawn_placement"] && String.to_atom(type["spawn_placement"]),
              spawn_heightmap: type["spawn_heightmap"],
              attributes: type["attributes"]
            }}
         end)

  def id("minecraft:" <> _ = name), do: Map.fetch!(@types, name).id
  def id(name) when is_binary(name), do: id("minecraft:" <> name)

  @names Map.new(@types, fn {name, type} -> {type.id, name} end)

  @doc "The type of registry id `id`."
  def name(id) when is_integer(id), do: Map.fetch!(@names, id)
  def names, do: unquote(Macro.escape(MapSet.new(Map.keys(@facts["types"]))))
  def field(name) when is_atom(name), do: @facts["fields"][Atom.to_string(name)]

  @doc "The facts of type `name` (with or without namespace), or nil."
  def fetch("minecraft:" <> _ = name), do: Map.get(@types, name)
  def fetch(name) when is_binary(name), do: fetch("minecraft:" <> name)

  @entity_tags Map.new(@tags["minecraft:entity_type"], fn {"minecraft:" <> tag, ids} ->
                 {tag, MapSet.new(ids)}
               end)

  @doc "Whether type `name` is in entity type tag `tag` (without namespace)."
  def tag?(name, tag), do: MapSet.member?(Map.fetch!(@entity_tags, tag), id(name))

  @doc "Whether type `name` is living (it has default attributes)."
  def living?(name), do: match?(%{attributes: %{}}, fetch(name))

  @doc "Vanilla's `clientTrackingRange` of a type, in chunks (VMC-070)."
  def tracking_range(name), do: fetch!(name).tracking_range

  @doc "A mob category's spawn cap and despawn rules."
  def category(name) when is_atom(name),
    do: Map.fetch!(@facts["categories"], Atom.to_string(name))

  defp fetch!(name), do: fetch(name) || raise(ArgumentError, "unknown entity type #{name}")
end
