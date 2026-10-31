defmodule Valimc.Protocol.ItemData do
  @moduledoc "Data-format component patches for server-authored item hovers."
  alias Valimc.Text.Codec
  alias Valimc.Data.EffectTypes

  alias Valimc.Protocol.{
    ComponentSchema,
    ComponentSchemas,
    Enchantments,
    ItemStack,
    LootComponents,
    ItemTypes,
    Wire
  }

  alias Valimc.Data.NBT

  @colors ["white", "yellow", "aqua", "light_purple"]
  @bucket_enums Valimc.Data.BucketFacts.enums()
  @transient ~w(minecraft:additional_trade_cost minecraft:creative_slot_lock minecraft:map_post_processing)

  def tag(%ItemStack{} = stack) do
    # Enforce the whole network stack bound before expanding component field names.
    ItemStack.encode(stack)
    item_tag(ItemStack.normalize(stack), true)
  end

  @doc """
  An item stack template's data form (`ItemStackTemplate.CODEC`, VMC-004b6).
  Unlike a stack's, a template's patch is kept as it is, defaults included.
  """
  def template_tag(%ItemStack{} = stack) do
    ItemStack.encode_template(stack)
    item_tag(stack, stack.count != 1)
  end

  @doc """
  The template a data form describes, its item alone (`"minecraft:stone"`) or
  `{id, count, components}`; throws `{:component_error, reason}` when invalid.
  """
  def template({:string, _} = id), do: template({:compound, %{"id" => id}})

  def template(tag) do
    case read(tag, &ItemStack.encode_template/1) do
      {:ok, %ItemStack{} = stack} -> stack
      {:unsupported, _} -> throw({:component_error, :unsupported_component})
      _ -> throw({:component_error, :invalid_template})
    end
  end

  defp item_tag(stack, count?) do
    components =
      for {name, value} <- stack.components, name not in @transient, into: %{} do
        {name, component(name, value)}
      end

    components =
      Enum.reduce(stack.removed, components, fn name, fields ->
        if name in @transient,
          do: fields,
          else: Map.put(fields, "!" <> name, {:compound, %{}})
      end)

    fields = %{"id" => {:string, ItemTypes.item(stack.item_id)["name"]}}
    fields = if count?, do: Map.put(fields, "count", {:int, stack.count}), else: fields

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
  def stack(tag), do: read(tag, &ItemStack.encode/1)

  defp read({:compound, fields}, check) do
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
          check.(stack)
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

  defp read(_, _), do: {:error, :invalid_item_tag}

  @int_max 2_147_483_647

  @doc """
  A component value as a command writes it (SNBT in `/give`, item predicates;
  vanilla's `ItemParser.readComponent`), decoded as the data format reads it
  (VMC-077o): `{:ok, value}`, `{:error, message}` with the codec's message, or
  `:unsupported` for a component ValiMC's stacks cannot hold.
  """
  def decode_component(name, tag) do
    case ItemStack.codec(name) do
      nil -> :unsupported
      {:varint, min, max} when name != "minecraft:rarity" -> int(tag, min, max)
      {:enum, names} -> enum_value(names, tag)
      kind when kind in [:unit, :nbt_unit] -> {:ok, :unit}
      :bool -> bool(tag)
      :nbt_compound -> if match?({:compound, _}, tag), do: {:ok, tag}, else: :unsupported
      :text -> text(tag)
      :lore -> lore(tag)
      _ -> structured(name, tag)
    end
  end

  defp enum_value(names, {:string, value}) do
    case Enum.find(names, fn {_id, name} -> name == value end) do
      {id, _} -> {:ok, id}
      nil -> {:error, "Unknown element name: #{value}"}
    end
  end

  defp enum_value(_names, _), do: {:error, "Not a string"}

  # `Codec.INT` over `NbtOps` (any number, as Java's `intValue()`) within the
  # codec's range, with `ExtraCodecs`' messages.
  defp int(tag, min, max) do
    case int_value(tag) do
      nil ->
        {:error, "Not a number"}

      value when value >= min and value <= max ->
        {:ok, value}

      value ->
        {:error,
         case {min, max} do
           {0, @int_max} -> "Value must be non-negative: #{value}"
           {1, @int_max} -> "Value must be positive: #{value}"
           _ -> "Value must be within range [#{min};#{max}]: #{value}"
         end}
    end
  end

  defp int_value({type, value}) when type in [:byte, :short, :int], do: value

  defp int_value({:long, value}) do
    <<int::signed-32>> = <<value::32>>
    int
  end

  defp int_value({:float, <<value::float-32>>}), do: saturate(value)
  defp int_value({:double, <<value::float-64>>}), do: saturate(value)
  defp int_value(_), do: nil

  defp saturate(value), do: value |> trunc() |> max(-2_147_483_648) |> min(@int_max)

  defp bool(tag) do
    case int_value(tag) do
      nil -> {:error, "Not a number"}
      value -> {:ok, Bitwise.band(value, 0xFF) != 0}
    end
  end

  # Text components through the one text codec; item text cannot hold events.
  defp text(tag) do
    with {:ok, component} <- Codec.decode(tag) do
      case Codec.check(component) do
        {:ok, _} -> {:ok, component}
        :unsupported -> :unsupported
        {:error, reason} -> {:error, "Invalid text: #{inspect(reason)}"}
      end
    end
  end

  defp lore({:list, _} = list) do
    Enum.reduce_while(NBT.items(list), {:ok, []}, fn line, {:ok, lines} ->
      case text(line) do
        {:ok, component} -> {:cont, {:ok, [component | lines]}}
        other -> {:halt, other}
      end
    end)
    |> case do
      {:ok, lines} ->
        lines = Enum.reverse(lines)
        if Codec.valid_lore?(lines), do: {:ok, lines}, else: {:error, "Too many lore lines"}

      other ->
        other
    end
  end

  defp lore(_tag), do: {:error, "Not a list"}

  # The data format's reader, kept only when the stack it makes encodes.
  defp structured(name, tag) do
    value = from_tag(name, tag)

    ItemStack.encode(%ItemStack{
      item_id: ItemTypes.id("stone"),
      count: 1,
      components: %{name => value}
    })

    {:ok, value}
  rescue
    _ -> {:error, "Invalid #{name} value"}
  catch
    _, _ -> {:error, "Invalid #{name} value"}
  end

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

  @doc "One component value from its data form (vanilla's `type.codec()`); throws when invalid."
  def component_value(name, tag) do
    if name not in ItemStack.supported_components(),
      do: throw({:component_error, :unsupported_component})

    from_tag(name, tag)
  end

  @doc "One component value's data form."
  def component_tag(name, value), do: component(name, value)

  # Schema components (VMC-004b4) through `ComponentSchema`, the rest by hand.
  defp from_tag(name, value) do
    case ComponentSchemas.schema(name) do
      nil -> legacy_from_tag(name, value)
      schema -> ComponentSchema.from_tag(schema, value)
    end
  end

  defp component(name, value) do
    case ComponentSchemas.schema(name) do
      nil -> legacy_component(name, value)
      schema -> ComponentSchema.to_tag(schema, value)
    end
  end

  defp legacy_from_tag(name, value)
       when name in ~w(minecraft:custom_data minecraft:bucket_entity_data minecraft:custom_name minecraft:item_name),
       do: value

  defp legacy_from_tag(name, {:string, _} = tag) when is_map_key(@bucket_enums, name) do
    {:ok, value} = enum_value(@bucket_enums[name], tag)
    value
  end

  defp legacy_from_tag("minecraft:lore", lines), do: elements(lines)

  defp legacy_from_tag(name, {:compound, levels})
       when name in ~w(minecraft:enchantments minecraft:stored_enchantments),
       do: Map.new(levels, fn {name, {_, level}} -> {qualified(name), level} end)

  defp legacy_from_tag(name, {:compound, _})
       when name in ~w(minecraft:unbreakable minecraft:intangible_projectile),
       do: :unit

  defp legacy_from_tag(name, {type, value})
       when name in ~w(minecraft:max_stack_size minecraft:max_damage minecraft:damage minecraft:repair_cost minecraft:ominous_bottle_amplifier minecraft:map_id) and
              type in [:byte, :short, :int],
       do: value

  defp legacy_from_tag("minecraft:suspicious_stew_effects", list),
    do: LootComponents.stew_from_tag(list)

  defp legacy_from_tag("minecraft:instrument", {:string, name}), do: qualified(name)

  defp legacy_from_tag("minecraft:block_state", {:compound, fields}),
    do: Map.new(fields, fn {name, {:string, value}} -> {name, value} end)

  defp legacy_from_tag("minecraft:map_decorations", decorations),
    do: LootComponents.decorations_from_tag(decorations)

  defp legacy_from_tag("minecraft:rarity", {:string, value}),
    do: Enum.find_index(~w(common uncommon rare epic), &(&1 == value)) || raise(ArgumentError)

  defp legacy_from_tag("minecraft:enchantment_glint_override", {:byte, value})
       when value in [0, 1],
       do: value == 1

  defp legacy_from_tag(name, {:string, value})
       when name in ~w(minecraft:item_model minecraft:tooltip_style),
       do: qualified(value)

  defp legacy_from_tag("minecraft:minimum_attack_charge", {:float, <<value::float-32>>}),
    do: value

  defp legacy_from_tag("minecraft:food", {:compound, fields}) do
    {_, nutrition} = fields["nutrition"]
    {:float, <<saturation::float-32>>} = fields["saturation"]

    %{
      nutrition: nutrition,
      saturation: saturation,
      can_always_eat: flag(fields["can_always_eat"], false)
    }
  end

  defp legacy_from_tag("minecraft:tooltip_display", {:compound, fields}) do
    hidden =
      case fields["hidden_components"] do
        nil -> MapSet.new()
        names -> MapSet.new(elements(names), fn {:string, name} -> qualified(name) end)
      end

    %Valimc.Protocol.TooltipDisplay{hide: flag(fields["hide_tooltip"], false), hidden: hidden}
  end

  defp legacy_from_tag("minecraft:potion_contents", {:string, potion}),
    do: %{Valimc.Protocol.PotionContents.empty() | potion: Valimc.Data.PotionTypes.id(potion)}

  defp legacy_from_tag("minecraft:potion_contents", {:compound, fields}) do
    effects =
      case fields["custom_effects"] do
        nil -> []
        effects -> Enum.map(elements(effects), &effect_from/1)
      end

    %{
      potion:
        case fields["potion"] do
          {:string, potion} -> Valimc.Data.PotionTypes.id(potion)
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
  defp elements(list), do: NBT.items(list)

  @doc """
  `ItemStack.getDisplayName`: the hover name (the custom name, in italics, or
  the item name) in square brackets, coloured by rarity (raised a step when
  enchanted), with the stack as its item hover.
  """
  def display_name(%ItemStack{} = stack) do
    custom = effective(stack, "minecraft:custom_name", nil, &Codec.take/1)
    name = custom || effective(stack, "minecraft:item_name", {:string, ""}, &Codec.take/1)
    {:compound, data} = tag(stack)
    hover = if stack.count == 1, do: Map.delete(data, "count"), else: data
    rarity = effective(stack, "minecraft:rarity", 0, &Wire.take_varint/1)
    enchanted = effective(stack, "minecraft:enchantments", %{}, &Enchantments.take/1)
    rarity = if map_size(enchanted) > 0, do: min(3, max(2, rarity + 1)), else: rarity
    hover_name = %{"text" => {:string, ""}, "extra" => NBT.list([name])}
    hover_name = if custom, do: Map.put(hover_name, "italic", {:byte, 1}), else: hover_name

    {:compound,
     %{
       "translate" => {:string, "chat.square_brackets"},
       "with" => NBT.list([{:compound, hover_name}]),
       "color" => {:string, Enum.at(@colors, rarity)},
       "hover_event" => {:compound, Map.put(hover, "action", {:string, "show_item"})}
     }}
  end

  @doc "`ItemStack.getItemName`: the stack's item name, which names its item entity."
  def item_name(%ItemStack{} = stack),
    do: effective(stack, "minecraft:item_name", {:string, ""}, &Codec.take/1)

  @doc "`display_name/1` of a stack with a custom name, else nil."
  def named_display(nil), do: nil

  def named_display(%ItemStack{} = stack) do
    if effective(stack, "minecraft:custom_name", nil, &Codec.take/1),
      do: display_name(stack)
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

  defp legacy_component(name, value)
       when name in ~w(minecraft:custom_data minecraft:bucket_entity_data minecraft:custom_name minecraft:item_name),
       do: value

  defp legacy_component(name, value) when is_map_key(@bucket_enums, name),
    do: {:string, @bucket_enums[name][value]}

  defp legacy_component("minecraft:lore", lines), do: NBT.list(lines)

  defp legacy_component(name, levels)
       when name in ~w(minecraft:enchantments minecraft:stored_enchantments),
       do: {:compound, Map.new(levels, fn {name, level} -> {name, {:int, level}} end)}

  defp legacy_component(name, :unit)
       when name in ~w(minecraft:unbreakable minecraft:intangible_projectile),
       do: {:compound, %{}}

  defp legacy_component(name, value)
       when name in ~w(minecraft:max_stack_size minecraft:max_damage minecraft:damage minecraft:repair_cost minecraft:ominous_bottle_amplifier minecraft:map_id),
       do: {:int, value}

  defp legacy_component("minecraft:suspicious_stew_effects", effects),
    do: LootComponents.stew_tag(effects)

  defp legacy_component("minecraft:instrument", name), do: {:string, name}

  defp legacy_component("minecraft:block_state", properties),
    do: {:compound, Map.new(properties, fn {name, value} -> {name, {:string, value}} end)}

  defp legacy_component("minecraft:map_decorations", decorations),
    do: LootComponents.decorations_tag(decorations)

  defp legacy_component("minecraft:rarity", value),
    do: {:string, Enum.at(~w(common uncommon rare epic), value)}

  defp legacy_component("minecraft:enchantment_glint_override", value), do: boolean(value)

  defp legacy_component(name, value)
       when name in ~w(minecraft:item_model minecraft:tooltip_style),
       do: {:string, value}

  defp legacy_component("minecraft:minimum_attack_charge", value), do: NBT.float(value)

  defp legacy_component("minecraft:food", value) do
    fields = %{
      "nutrition" => {:int, value.nutrition},
      "saturation" => NBT.float(value.saturation)
    }

    {:compound,
     if(value.can_always_eat, do: Map.put(fields, "can_always_eat", boolean(true)), else: fields)}
  end

  defp legacy_component("minecraft:tooltip_display", value) do
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

  defp legacy_component("minecraft:potion_contents", value) do
    fields = %{}

    fields =
      if value.potion == nil,
        do: fields,
        else: Map.put(fields, "potion", {:string, Valimc.Data.PotionTypes.name(value.potion)})

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
