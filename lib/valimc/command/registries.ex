defmodule Valimc.Command.Registries do
  @moduledoc """
  Registry entries and tags that command arguments resolve (VMC-053), from the
  generated block, item, entity, effect and synchronized registry facts.
  """
  alias Valimc.Protocol.Data

  @entity_types Valimc.Protocol.EntityTypes.names()
  @effects for id <- 0..(Valimc.Protocol.EffectTypes.count() - 1),
               into: MapSet.new(),
               do: Valimc.Protocol.EffectTypes.name(id)

  @doc "Whether `id` (`namespace:path`) names an entry of `registry`."
  def entry?("minecraft:block", "minecraft:" <> name), do: Valimc.Registry.Blocks.id(name) != nil
  def entry?("minecraft:block", _), do: false
  def entry?("minecraft:item", id), do: item_id(id) != nil
  def entry?("minecraft:entity_type", id), do: MapSet.member?(@entity_types, id)
  def entry?("minecraft:mob_effect", id), do: MapSet.member?(@effects, id)
  def entry?(registry, id), do: Data.find_registry_id(registry, id) != nil

  def component?(id), do: Valimc.Protocol.ComponentTypes.id(id) != nil

  def item_id(id) do
    Valimc.Protocol.ItemTypes.id(id)
  rescue
    _ -> nil
  end

  @doc "The member ids of tag `id` in `registry`, or nil when no such tag exists."
  def tag(registry, id), do: get_in(Data.tags(), [registry, id])
end
