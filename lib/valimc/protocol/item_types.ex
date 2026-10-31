defmodule Valimc.Protocol.ItemTypes do
  @moduledoc "Indexed item and component facts from the pinned Mojang 26.3 runtime."
  use Valimc.Data.Facts, "protocol/items.json"

  @items @facts["items"]
  @by_id Map.new(@items, fn {name, facts} -> {facts["id"], Map.put(facts, "name", name)} end)
  @actions @facts["player_actions"]
  @inputs @facts["container_inputs"]
  @input_names Map.new(~w(pickup quick_move swap clone throw quick_craft pickup_all), fn name ->
                 {Map.fetch!(@inputs, name), String.to_atom(name)}
               end)
  use Valimc.Data.Facts, file: "protocol/item_defaults.json", as: :default_facts

  # Distinct default values (most items share their common components), decoded
  # once; identity keys are computed once per value and component.
  @default_values @default_facts["values"]
                  |> Enum.map(&Base.decode16!(&1, case: :lower))
                  |> List.to_tuple()
  @default_keys @default_facts["items"]
                |> Enum.flat_map(fn {_, facts} -> facts["values"] end)
                |> Enum.uniq()
                |> Map.new(fn {name, index} ->
                  bytes = elem(@default_values, index)

                  key =
                    case name do
                      name when name in ["minecraft:custom_name", "minecraft:item_name"] ->
                        {tag, <<>>} = Valimc.Text.Codec.take(bytes)
                        Valimc.Text.Codec.identity_key(tag)

                      "minecraft:lore" ->
                        {lines, <<>>} = Valimc.Text.Codec.take_lore(bytes)
                        Valimc.Text.Codec.lore_key(lines)

                      "minecraft:custom_data" ->
                        {:ok, tag} = Valimc.Data.NBT.decode(bytes)
                        Valimc.Data.NBT.identity_key(tag)

                      "minecraft:tooltip_display" ->
                        {value, <<>>} = Valimc.Protocol.TooltipDisplay.take(bytes)
                        Valimc.Protocol.TooltipDisplay.identity_key(value)

                      "minecraft:potion_contents" ->
                        {value, <<>>} = Valimc.Protocol.PotionContents.take(bytes)
                        Valimc.Protocol.PotionContents.identity_key(value)

                      # Mojang's encoding is canonical for every other codec.
                      _ ->
                        bytes
                    end

                  {{name, index}, key}
                end)

  @defaults @default_facts["items"]
            |> Map.new(fn {id, facts} ->
              {String.to_integer(id),
               %{
                 present: MapSet.new(facts["present"]),
                 values:
                   Map.new(facts["values"], fn {name, index} ->
                     {name, elem(@default_values, index)}
                   end),
                 identities:
                   Map.new(facts["values"], fn {name, index} ->
                     {name, Map.fetch!(@default_keys, {name, index})}
                   end)
               }}
            end)

  def item(id), do: @by_id[id]
  def count, do: unquote(map_size(@by_id))
  def id(name), do: Map.fetch!(@items, qualified(name))["id"]
  def known?(name), do: Map.has_key?(@items, qualified(name))
  def component(id), do: Valimc.Data.ComponentTypes.name(id)
  def component_id(name), do: Valimc.Data.ComponentTypes.id(name)
  def component_count, do: Valimc.Data.ComponentTypes.count()
  def defaults(id), do: Map.fetch!(@defaults, id)
  def action_id(name), do: Map.fetch!(@actions, name)
  def input_id(name), do: Map.fetch!(@inputs, name)
  def input(id), do: @input_names[id]
  defp qualified("minecraft:" <> _ = name), do: name
  defp qualified(name), do: "minecraft:" <> name
end
