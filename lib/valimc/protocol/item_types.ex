defmodule Valimc.Protocol.ItemTypes do
  @moduledoc "Indexed item and component facts from the pinned Mojang 26.3 runtime."
  @path Path.expand("../../../priv/protocol/items.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @items @facts["items"]
  @by_id Map.new(@items, fn {name, facts} -> {facts["id"], Map.put(facts, "name", name)} end)
  @components @facts["components"]
  @component_names Map.new(@components, fn {name, id} -> {id, name} end)

  def item(id), do: @by_id[id]
  def id(name), do: Map.fetch!(@items, qualified(name))["id"]
  def component(id), do: @component_names[id]
  def component_id(name), do: @components[qualified(name)]
  def component_count, do: map_size(@components)
  defp qualified("minecraft:" <> _ = name), do: name
  defp qualified(name), do: "minecraft:" <> name
end
