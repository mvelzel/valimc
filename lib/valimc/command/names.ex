defmodule Valimc.Command.Names do
  @moduledoc "Display names that vanilla command feedback embeds (VMC-053): items, effects, modes."
  alias Valimc.Text
  alias Valimc.Protocol.ItemTypes

  @rarities {"white", "yellow", "aqua", "light_purple"}

  @doc """
  `ItemStack.getDisplayName` of a component-free stack of one: the item name in
  square brackets, coloured by rarity, with an item hover.
  """
  def item(item_id) do
    values = ItemTypes.defaults(item_id).values
    {:ok, name, ""} = Valimc.NBT.take(values["minecraft:item_name"])
    <<rarity>> = Map.get(values, "minecraft:rarity", <<0>>)

    Text.translatable("chat.square_brackets", [Text.empty() |> Text.append(name)])
    |> Text.style([
      {"color", elem(@rarities, rarity)},
      {"hover_event",
       {:compound,
        %{
          "action" => {:string, "show_item"},
          "id" => {:string, ItemTypes.item(item_id)["name"]}
        }}}
    ])
  end

  def effect("minecraft:" <> name), do: Text.translatable("effect.minecraft.#{name}")
  def game_mode(mode), do: Text.translatable("gameMode.#{mode}")

  def difficulty(level),
    do:
      Text.translatable(
        "options.difficulty.#{elem({"peaceful", "easy", "normal", "hard"}, level)}"
      )
end
