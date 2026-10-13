defmodule Valimc.Protocol.ItemTypes do
  @moduledoc "Indexed item and component facts from the pinned Mojang 26.3 runtime."
  @path Path.expand("../../../priv/protocol/items.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  @items @facts["items"]
  @by_id Map.new(@items, fn {name, facts} -> {facts["id"], Map.put(facts, "name", name)} end)
  @components @facts["components"]
  @actions @facts["player_actions"]
  @inputs @facts["container_inputs"]
  @input_names Map.new(~w(pickup quick_move swap clone throw quick_craft pickup_all), fn name ->
                 {Map.fetch!(@inputs, name), String.to_atom(name)}
               end)
  @component_names Map.new(@components, fn {name, id} -> {id, name} end)

  def item(id), do: @by_id[id]
  def id(name), do: Map.fetch!(@items, qualified(name))["id"]
  def component(id), do: @component_names[id]
  def component_id(name), do: @components[qualified(name)]
  def component_count, do: map_size(@components)
  def action_id(name), do: Map.fetch!(@actions, name)
  def input_id(name), do: Map.fetch!(@inputs, name)
  def input(id), do: @input_names[id]
  defp qualified("minecraft:" <> _ = name), do: name
  defp qualified(name), do: "minecraft:" <> name
end
