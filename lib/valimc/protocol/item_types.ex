defmodule Valimc.Protocol.ItemTypes do
  @moduledoc "Indexed item and component facts from the pinned Mojang 26.3 runtime."
  @path Path.expand("../../../priv/protocol/items.json", __DIR__)
  @external_resource @path
  @facts :json.decode(File.read!(@path))
  unless Valimc.Version.stamped?(@facts, ~w(version protocol)),
    do: raise("Wrong item facts")

  @items @facts["items"]
  @by_id Map.new(@items, fn {name, facts} -> {facts["id"], Map.put(facts, "name", name)} end)
  @actions @facts["player_actions"]
  @inputs @facts["container_inputs"]
  @input_names Map.new(~w(pickup quick_move swap clone throw quick_craft pickup_all), fn name ->
                 {Map.fetch!(@inputs, name), String.to_atom(name)}
               end)
  @defaults_path Path.expand("../../../priv/protocol/item_defaults.json", __DIR__)
  @external_resource @defaults_path
  @default_facts :json.decode(File.read!(@defaults_path))
  unless Valimc.Version.stamped?(@default_facts, ~w(version data_version protocol server_sha1)),
    do: raise("Wrong item default facts")

  @defaults @default_facts["items"]
            |> Map.new(fn {id, facts} ->
              values =
                Map.new(facts["values"], fn {name, bytes} ->
                  {name, Base.decode16!(bytes, case: :lower)}
                end)

              identities =
                Map.new(values, fn {name, bytes} ->
                  key =
                    case name do
                      name when name in ["minecraft:custom_name", "minecraft:item_name"] ->
                        {tag, <<>>} = Valimc.Protocol.TextComponent.take(bytes)
                        Valimc.Protocol.TextComponent.identity_key(tag)

                      "minecraft:lore" ->
                        {lines, <<>>} = Valimc.Protocol.TextComponent.take_lore(bytes)
                        Valimc.Protocol.TextComponent.lore_key(lines)

                      "minecraft:custom_data" ->
                        {:ok, tag} = Valimc.Protocol.NBT.decode(bytes)
                        Valimc.Protocol.NBT.identity_key(tag)

                      "minecraft:tooltip_display" ->
                        {value, <<>>} = Valimc.Protocol.TooltipDisplay.take(bytes)
                        Valimc.Protocol.TooltipDisplay.identity_key(value)

                      "minecraft:potion_contents" ->
                        {value, <<>>} = Valimc.Protocol.PotionContents.take(bytes)
                        Valimc.Protocol.PotionContents.identity_key(value)

                      _ ->
                        bytes
                    end

                  {name, key}
                end)

              {String.to_integer(id),
               %{
                 present: MapSet.new(facts["present"]),
                 values: values,
                 identities: identities
               }}
            end)

  def item(id), do: @by_id[id]
  def count, do: unquote(map_size(@by_id))
  def id(name), do: Map.fetch!(@items, qualified(name))["id"]
  def component(id), do: Valimc.Protocol.ComponentTypes.name(id)
  def component_id(name), do: Valimc.Protocol.ComponentTypes.id(name)
  def component_count, do: Valimc.Protocol.ComponentTypes.count()
  def defaults(id), do: Map.fetch!(@defaults, id)
  def action_id(name), do: Map.fetch!(@actions, name)
  def input_id(name), do: Map.fetch!(@inputs, name)
  def input(id), do: @input_names[id]
  defp qualified("minecraft:" <> _ = name), do: name
  defp qualified(name), do: "minecraft:" <> name
end
