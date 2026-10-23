defmodule Valimc.Protocol.DamageTypes do
  @moduledoc """
  Damage types by name (`:fall`, `:in_fire`, ...): their registry ids and
  their tags (`:is_fire`, `:bypasses_armor`, ...), from the generated
  registries and tags. Rules ask a type's tags instead of listing types.
  """
  alias Valimc.Protocol.Data

  @ids Data.registries()["minecraft:damage_type"]
       |> Enum.with_index()
       |> Map.new(fn {"minecraft:" <> name, id} -> {String.to_atom(name), id} end)
  @tags Map.new(Data.tags()["minecraft:damage_type"], fn {"minecraft:" <> tag, ids} ->
          {String.to_atom(tag), MapSet.new(ids)}
        end)

  def known?(type), do: Map.has_key?(@ids, type)

  @doc "The registry id of a damage type; an unknown type raises."
  def id(type), do: Map.fetch!(@ids, type)

  @doc "Whether damage type `type` has tag `tag` (an unknown tag raises)."
  def tag?(type, tag), do: MapSet.member?(Map.fetch!(@tags, tag), id(type))

  @doc "The tags of damage type `type`, namespaced (loot's `damage_source_properties`)."
  def tags_of(type) do
    id = id(type)
    for {tag, ids} <- @tags, MapSet.member?(ids, id), do: "minecraft:#{tag}"
  end
end
