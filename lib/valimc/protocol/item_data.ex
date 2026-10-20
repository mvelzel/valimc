defmodule Valimc.Protocol.ItemData do
  @moduledoc "Data-format component patches for server-authored item hovers."
  alias Valimc.Protocol.{
    EffectTypes,
    Enchantments,
    ItemStack,
    ItemTypes,
    TextComponent,
    Wire
  }

  alias Valimc.NBT

  @colors ["white", "yellow", "aqua", "light_purple"]
  @transient ~w(minecraft:additional_trade_cost minecraft:creative_slot_lock minecraft:map_post_processing)

  def tag(%ItemStack{} = stack) do
    # Enforce the whole network stack bound before expanding component field names.
    ItemStack.encode(stack)
    {_, added, removed} = ItemStack.identity_key(stack)

    components =
      for {name, _} <- added, name not in @transient, into: %{} do
        {name, component(name, Map.fetch!(stack.components, name))}
      end

    components =
      Enum.reduce(removed, components, fn name, fields ->
        if name in @transient,
          do: fields,
          else: Map.put(fields, "!" <> name, {:compound, %{}})
      end)

    fields = %{
      "id" => {:string, ItemTypes.item(stack.item_id)["name"]},
      "count" => {:int, stack.count}
    }

    {:compound,
     if(map_size(components) == 0,
       do: fields,
       else: Map.put(fields, "components", {:compound, components})
     )}
  end

  def named_display(nil), do: nil

  def named_display(%ItemStack{} = stack) do
    case effective(stack, "minecraft:custom_name", nil, &TextComponent.take/1) do
      nil ->
        nil

      name ->
        {:compound, data} = tag(stack)
        hover = if stack.count == 1, do: Map.delete(data, "count"), else: data
        rarity = effective(stack, "minecraft:rarity", 0, &Wire.take_varint/1)
        enchanted = effective(stack, "minecraft:enchantments", %{}, &Enchantments.take/1)
        rarity = if map_size(enchanted) > 0, do: min(3, max(2, rarity + 1)), else: rarity

        {:compound,
         %{
           "translate" => {:string, "chat.square_brackets"},
           "with" =>
             NBT.list([
               {:compound,
                %{"text" => {:string, ""}, "italic" => {:byte, 1}, "extra" => NBT.list([name])}}
             ]),
           "color" => {:string, Enum.at(@colors, rarity)},
           "hover_event" => {:compound, Map.put(hover, "action", {:string, "show_item"})}
         }}
    end
  end

  defp effective(stack, name, absent, decoder) do
    cond do
      MapSet.member?(stack.removed, name) ->
        absent

      Map.has_key?(stack.components, name) ->
        stack.components[name]

      bytes = ItemTypes.defaults(stack.item_id).values[name] ->
        {value, <<>>} = decoder.(bytes)
        value

      true ->
        absent
    end
  end

  defp component(name, value)
       when name in ~w(minecraft:custom_data minecraft:custom_name minecraft:item_name), do: value

  defp component("minecraft:lore", lines), do: NBT.list(lines)

  defp component(name, levels)
       when name in ~w(minecraft:enchantments minecraft:stored_enchantments),
       do: {:compound, Map.new(levels, fn {name, level} -> {name, {:int, level}} end)}

  defp component(name, :unit)
       when name in ~w(minecraft:unbreakable minecraft:intangible_projectile),
       do: {:compound, %{}}

  defp component(name, value)
       when name in ~w(minecraft:max_stack_size minecraft:max_damage minecraft:damage minecraft:repair_cost),
       do: {:int, value}

  defp component("minecraft:rarity", value),
    do: {:string, Enum.at(~w(common uncommon rare epic), value)}

  defp component("minecraft:enchantment_glint_override", value), do: boolean(value)

  defp component(name, value) when name in ~w(minecraft:item_model minecraft:tooltip_style),
    do: {:string, value}

  defp component("minecraft:minimum_attack_charge", value), do: NBT.float(value)

  defp component("minecraft:food", value) do
    fields = %{
      "nutrition" => {:int, value.nutrition},
      "saturation" => NBT.float(value.saturation)
    }

    {:compound,
     if(value.can_always_eat, do: Map.put(fields, "can_always_eat", boolean(true)), else: fields)}
  end

  defp component("minecraft:tooltip_display", value) do
    fields = if value.hide, do: %{"hide_tooltip" => boolean(true)}, else: %{}

    fields =
      if MapSet.size(value.hidden) == 0,
        do: fields,
        else:
          Map.put(
            fields,
            "hidden_components",
            NBT.list(Enum.map(Enum.sort(value.hidden), &{:string, &1}))
          )

    {:compound, fields}
  end

  defp component("minecraft:potion_contents", value) do
    fields = %{}

    fields =
      if value.potion == nil,
        do: fields,
        else: Map.put(fields, "potion", {:string, Valimc.Protocol.PotionTypes.name(value.potion)})

    fields =
      if value.color == nil,
        do: fields,
        else: Map.put(fields, "custom_color", {:int, value.color})

    fields =
      if value.name == nil,
        do: fields,
        else: Map.put(fields, "custom_name", {:string, value.name})

    fields =
      if value.effects == [],
        do: fields,
        else: Map.put(fields, "custom_effects", NBT.list(Enum.map(value.effects, &effect/1)))

    {:compound, fields}
  end

  defp effect({id, [{ticks, amp, ambient, particles, icon} | _]}) do
    fields = %{"id" => {:string, EffectTypes.name(id)}}

    fields =
      if amp == 0,
        do: fields,
        else: Map.put(fields, "amplifier", {:byte, if(amp > 127, do: amp - 256, else: amp)})

    fields = if ticks == 0, do: fields, else: Map.put(fields, "duration", {:int, ticks})
    fields = if ambient, do: Map.put(fields, "ambient", boolean(true)), else: fields
    fields = if particles, do: fields, else: Map.put(fields, "show_particles", boolean(false))
    fields = Map.put(fields, "show_icon", boolean(icon))
    {:compound, fields}
  end

  defp boolean(value), do: {:byte, if(value, do: 1, else: 0)}
end
