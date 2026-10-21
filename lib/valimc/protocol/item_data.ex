defmodule Valimc.Protocol.ItemData do
  @moduledoc "Data-format component patches for server-authored item hovers."
  alias Valimc.Protocol.{
    EffectTypes,
    Enchantments,
    ItemStack,
    LootComponents,
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

  @doc """
  The stack a data-format item tag describes (`{id, count, components}` as world
  files store it; the inverse of `tag/1`): `{:ok, stack}`, `{:ok, nil}` for air,
  `{:unsupported, names}` when it uses components ValiMC cannot hold yet, or
  `{:error, reason}`.
  """
  def stack({:compound, fields}) do
    with {:string, name} <- fields["id"],
         {:ok, id} <- item_id(name),
         {:ok, count} <- count(fields["count"]),
         {:ok, patch} <- patch(fields["components"]) do
      {added, removed} =
        Enum.reduce(patch, {%{}, MapSet.new()}, fn
          {"!" <> name, _}, {added, removed} -> {added, MapSet.put(removed, qualified(name))}
          {name, value}, {added, removed} -> {Map.put(added, qualified(name), value), removed}
        end)

      case Enum.reject(Map.keys(added), &(&1 in ItemStack.supported_components())) do
        [] ->
          components = Map.new(added, fn {name, value} -> {name, from_tag(name, value)} end)

          stack = %ItemStack{
            item_id: id,
            count: count,
            components: components,
            removed: removed
          }

          # The network encoder enforces every component and stack bound.
          ItemStack.encode(stack)
          {:ok, if(name in ["minecraft:air", "air"], do: nil, else: stack)}

        names ->
          {:unsupported, Enum.sort(names)}
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_item_tag}
    end
  rescue
    _ -> {:error, :invalid_item_component}
  catch
    _, _ -> {:error, :invalid_item_component}
  end

  def stack(_), do: {:error, :invalid_item_tag}

  defp item_id(name) do
    {:ok, ItemTypes.id(name)}
  rescue
    _ -> {:error, :unknown_item}
  end

  defp count(nil), do: {:ok, 1}

  defp count({type, count}) when type in [:byte, :short, :int] and count in 1..99,
    do: {:ok, count}

  defp count(_), do: {:error, :invalid_item_count}

  defp patch(nil), do: {:ok, []}
  defp patch({:compound, components}), do: {:ok, Map.to_list(components)}
  defp patch(_), do: {:error, :invalid_item_components}

  defp qualified("minecraft:" <> _ = name), do: name
  defp qualified(name), do: if(String.contains?(name, ":"), do: name, else: "minecraft:" <> name)

  defp from_tag(name, value)
       when name in ~w(minecraft:custom_data minecraft:custom_name minecraft:item_name),
       do: value

  defp from_tag("minecraft:lore", lines), do: elements(lines)

  defp from_tag(name, {:compound, levels})
       when name in ~w(minecraft:enchantments minecraft:stored_enchantments),
       do: Map.new(levels, fn {name, {_, level}} -> {qualified(name), level} end)

  defp from_tag(name, {:compound, _})
       when name in ~w(minecraft:unbreakable minecraft:intangible_projectile),
       do: :unit

  defp from_tag(name, {type, value})
       when name in ~w(minecraft:max_stack_size minecraft:max_damage minecraft:damage minecraft:repair_cost minecraft:ominous_bottle_amplifier minecraft:map_id) and
              type in [:byte, :short, :int],
       do: value

  defp from_tag("minecraft:suspicious_stew_effects", list), do: LootComponents.stew_from_tag(list)
  defp from_tag("minecraft:instrument", {:string, name}), do: qualified(name)

  defp from_tag("minecraft:map_decorations", decorations),
    do: LootComponents.decorations_from_tag(decorations)

  defp from_tag("minecraft:rarity", {:string, value}),
    do: Enum.find_index(~w(common uncommon rare epic), &(&1 == value)) || raise(ArgumentError)

  defp from_tag("minecraft:enchantment_glint_override", {:byte, value}) when value in [0, 1],
    do: value == 1

  defp from_tag(name, {:string, value})
       when name in ~w(minecraft:item_model minecraft:tooltip_style),
       do: qualified(value)

  defp from_tag("minecraft:minimum_attack_charge", {:float, <<value::float-32>>}), do: value

  defp from_tag("minecraft:food", {:compound, fields}) do
    {_, nutrition} = fields["nutrition"]
    {:float, <<saturation::float-32>>} = fields["saturation"]

    %{
      nutrition: nutrition,
      saturation: saturation,
      can_always_eat: flag(fields["can_always_eat"], false)
    }
  end

  defp from_tag("minecraft:tooltip_display", {:compound, fields}) do
    hidden =
      case fields["hidden_components"] do
        nil -> MapSet.new()
        names -> MapSet.new(elements(names), fn {:string, name} -> qualified(name) end)
      end

    %Valimc.Protocol.TooltipDisplay{hide: flag(fields["hide_tooltip"], false), hidden: hidden}
  end

  defp from_tag("minecraft:potion_contents", {:string, potion}),
    do: %{Valimc.Protocol.PotionContents.empty() | potion: Valimc.Protocol.PotionTypes.id(potion)}

  defp from_tag("minecraft:potion_contents", {:compound, fields}) do
    effects =
      case fields["custom_effects"] do
        nil -> []
        effects -> Enum.map(elements(effects), &effect_from/1)
      end

    %{
      potion:
        case fields["potion"] do
          {:string, potion} -> Valimc.Protocol.PotionTypes.id(potion)
          nil -> nil
        end,
      color:
        case fields["custom_color"] do
          {:int, color} -> color
          nil -> nil
        end,
      effects: effects,
      name:
        case fields["custom_name"] do
          {:string, name} -> name
          nil -> nil
        end
    }
  end

  defp effect_from({:compound, fields}) do
    {:string, id} = fields["id"]
    {EffectTypes.id(id), rungs(fields)}
  end

  # `hidden_effect` nests the weaker effect a stronger one suppresses.
  defp rungs(fields) do
    amplifier =
      case fields["amplifier"] do
        nil -> 0
        {:byte, amp} -> Bitwise.band(amp, 255)
      end

    duration =
      case fields["duration"] do
        nil -> 0
        {:int, ticks} -> ticks
      end

    particles = flag(fields["show_particles"], true)

    head =
      {duration, amplifier, flag(fields["ambient"], false), particles,
       flag(fields["show_icon"], particles)}

    case fields["hidden_effect"] do
      nil -> [head]
      {:compound, hidden} -> [head | rungs(hidden)]
    end
  end

  defp flag(nil, default), do: default
  defp flag({:byte, value}, _) when value in [0, 1], do: value == 1

  # List elements as tags; vanilla unwraps `{"": tag}` compound elements on load.
  defp elements({:list, {type, values}}) do
    Enum.map(values, fn
      %{"" => tag} = wrapper when type == :compound and map_size(wrapper) == 1 -> tag
      value -> {type, value}
    end)
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
       when name in ~w(minecraft:max_stack_size minecraft:max_damage minecraft:damage minecraft:repair_cost minecraft:ominous_bottle_amplifier minecraft:map_id),
       do: {:int, value}

  defp component("minecraft:suspicious_stew_effects", effects),
    do: LootComponents.stew_tag(effects)

  defp component("minecraft:instrument", name), do: {:string, name}

  defp component("minecraft:map_decorations", decorations),
    do: LootComponents.decorations_tag(decorations)

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

  defp effect({id, rungs}),
    do: {:compound, Map.put(details(rungs), "id", {:string, EffectTypes.name(id)})}

  # `hidden_effect` nests the weaker rung a stronger one suppresses.
  defp details([{ticks, amp, ambient, particles, icon} | hidden]) do
    fields = %{}

    fields =
      if amp == 0,
        do: fields,
        else: Map.put(fields, "amplifier", {:byte, if(amp > 127, do: amp - 256, else: amp)})

    fields = if ticks == 0, do: fields, else: Map.put(fields, "duration", {:int, ticks})
    fields = if ambient, do: Map.put(fields, "ambient", boolean(true)), else: fields
    fields = if particles, do: fields, else: Map.put(fields, "show_particles", boolean(false))
    fields = Map.put(fields, "show_icon", boolean(icon))

    case hidden do
      [] -> fields
      _ -> Map.put(fields, "hidden_effect", {:compound, details(hidden)})
    end
  end

  defp boolean(value), do: {:byte, if(value, do: 1, else: 0)}
end
