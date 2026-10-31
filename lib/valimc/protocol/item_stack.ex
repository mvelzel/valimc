defmodule Valimc.Protocol.ItemStack do
  @moduledoc "Pure bounded 26.3 stacks. Unsupported structured patches never become accepted data."
  alias Valimc.Text.Codec

  alias Valimc.Protocol.{
    ComponentSchema,
    ComponentSchemas,
    Enchantments,
    FoodProperties,
    ItemTypes,
    LootComponents,
    PotionContents,
    TooltipDisplay,
    Wire
  }

  alias Valimc.Data.NBT

  defstruct [:item_id, count: 1, components: %{}, removed: MapSet.new()]

  @max_bytes 65_536
  @codecs %{
    "minecraft:custom_data" => :nbt_compound,
    "minecraft:bucket_entity_data" => :nbt_compound,
    "minecraft:salmon/size" => {:enum, Valimc.Data.BucketFacts.enum("minecraft:salmon/size")},
    "minecraft:axolotl/variant" =>
      {:enum, Valimc.Data.BucketFacts.enum("minecraft:axolotl/variant")},
    "minecraft:tropical_fish/pattern" =>
      {:enum, Valimc.Data.BucketFacts.enum("minecraft:tropical_fish/pattern")},
    "minecraft:tropical_fish/base_color" =>
      {:enum, Valimc.Data.BucketFacts.enum("minecraft:tropical_fish/base_color")},
    "minecraft:tropical_fish/pattern_color" =>
      {:enum, Valimc.Data.BucketFacts.enum("minecraft:tropical_fish/pattern_color")},
    "minecraft:custom_name" => :text,
    "minecraft:item_name" => :text,
    "minecraft:lore" => :lore,
    "minecraft:enchantments" => :enchantments,
    "minecraft:stored_enchantments" => :enchantments,
    "minecraft:tooltip_display" => :tooltip,
    "minecraft:food" => :food,
    "minecraft:potion_contents" => :potion_contents,
    "minecraft:max_stack_size" => {:varint, 1, 99},
    "minecraft:max_damage" => {:varint, 1, 2_147_483_647},
    "minecraft:damage" => {:varint, 0, 2_147_483_647},
    "minecraft:repair_cost" => {:varint, 0, 2_147_483_647},
    "minecraft:rarity" => {:varint, 0, 3},
    "minecraft:unbreakable" => :unit,
    "minecraft:creative_slot_lock" => :unit,
    "minecraft:intangible_projectile" => :nbt_unit,
    # A loaded crossbow's projectiles (VMC-037o).
    "minecraft:charged_projectiles" => :charged_projectiles,
    "minecraft:enchantment_glint_override" => :bool,
    "minecraft:item_model" => :identifier,
    "minecraft:tooltip_style" => :identifier,
    "minecraft:minimum_attack_charge" => :fraction,
    # Container loot (VMC-072a).
    "minecraft:suspicious_stew_effects" => :stew_effects,
    "minecraft:instrument" => :instrument,
    "minecraft:ominous_bottle_amplifier" => {:varint, 0, 4},
    "minecraft:map_id" => {:varint, 0, 2_147_483_647},
    "minecraft:map_decorations" => :map_decorations,
    # Block loot's `copy_state` (VMC-029e).
    "minecraft:block_state" => :block_state
  }
  # Every other type is read and written from its schema (VMC-004b4).
  @codecs Map.merge(
            @codecs,
            Map.new(ComponentSchemas.names(), &{&1, {:schema, ComponentSchemas.schema(&1)}})
          )
  # Persistent components vanilla never sends to clients.
  @unsynced ["minecraft:map_decorations"]

  def new(name, count \\ 1), do: %__MODULE__{item_id: ItemTypes.id(name), count: count}
  def supported_components, do: Map.keys(@codecs)

  @doc "The wire codec kind of a supported component, or nil."
  def codec(name), do: Map.get(@codecs, name)

  @doc "Count-independent effective identity; raw codec/journal patches remain unchanged."
  def identity_key(%__MODULE__{} = stack) do
    validate!(stack)
    defaults = ItemTypes.defaults(stack.item_id)

    added =
      stack.components
      |> Enum.map(fn {name, value} ->
        {name, component_key(Map.fetch!(@codecs, name), value)}
      end)
      |> Enum.reject(fn {name, key} -> defaults.identities[name] == key end)
      |> Enum.sort()

    removed = stack.removed |> Enum.filter(&MapSet.member?(defaults.present, &1)) |> Enum.sort()
    {stack.item_id, added, removed}
  end

  @doc "The stack without patch entries equal to its item's defaults, as vanilla's patch keeps them."
  def normalize(%__MODULE__{} = stack) do
    {_, added, removed} = identity_key(stack)

    %{
      stack
      | components: Map.take(stack.components, Enum.map(added, &elem(&1, 0))),
        removed: MapSet.new(removed)
    }
  end

  def same_item?(%__MODULE__{item_id: id} = a, %__MODULE__{item_id: id} = b),
    do: identity_key(a) == identity_key(b)

  def same_item?(nil, nil), do: true

  def same_item?(_, _), do: false

  def decode(bytes, mode \\ :trusted) do
    case take(bytes, mode) do
      {:ok, stack, <<>>} -> {:ok, stack}
      {:unsupported, names, <<>>} -> {:unsupported, names}
      {:error, _} = error -> error
      _ -> {:error, :trailing_item_bytes}
    end
  end

  def take(bytes, mode \\ :trusted) when mode in [:trusted, :untrusted] do
    {count, rest} = Wire.take_varint(bytes)

    if count == 0 do
      {:ok, nil, rest}
    else
      check(count in 1..99, :invalid_item_count)
      {id, rest} = Wire.take_varint(rest)
      check(ItemTypes.item(id) != nil, :unknown_item)
      {added, rest} = Wire.take_varint(rest)
      {removed, rest} = Wire.take_varint(rest)
      check(added + removed <= ItemTypes.component_count(), :component_count_limit)
      size = byte_size(bytes)

      {components, unsupported, rest} = read_added(rest, added, mode, size, %{}, [])
      {removed, rest} = read_removed(rest, removed, MapSet.new(), components)
      check(size - byte_size(rest) <= @max_bytes, :item_byte_limit)

      if unsupported != [] do
        {:unsupported, Enum.reverse(unsupported), rest}
      else
        stack = %__MODULE__{item_id: id, count: count, components: components, removed: removed}
        validate!(stack)
        # Vanilla normalizes positive-count air stacks to empty.
        {:ok, if(id == ItemTypes.id("air"), do: nil, else: stack), rest}
      end
    end
  rescue
    ArgumentError -> {:error, :malformed_item}
    MatchError -> {:error, :malformed_item}
  catch
    {:item_error, reason} -> {:error, reason}
    {:text_error, reason} -> {:error, {:text, reason}}
    {:enchantment_error, reason} -> {:error, {:enchantments, reason}}
    {:tooltip_error, reason} -> {:error, {:tooltip, reason}}
    {:component_error, reason} -> {:error, {:component, reason}}
  end

  def encode(stack, mode \\ :trusted)
  def encode(nil, mode) when mode in [:trusted, :untrusted], do: <<0>>

  def encode(%__MODULE__{} = stack, mode) when mode in [:trusted, :untrusted] do
    validate!(stack)

    added =
      stack.components
      |> Enum.reject(fn {name, _} -> name in @unsynced end)
      |> Enum.sort_by(fn {name, _} -> ItemTypes.component_id(name) end)

    removed = Enum.sort_by(stack.removed, &ItemTypes.component_id/1)

    bytes = [
      Wire.varint(stack.count),
      Wire.varint(stack.item_id),
      Wire.varint(length(added)),
      Wire.varint(length(removed)),
      Enum.map(added, fn {name, value} ->
        encoded = encode_component(Map.fetch!(@codecs, name), value)
        length = if mode == :untrusted, do: Wire.varint(IO.iodata_length(encoded)), else: []
        [Wire.varint(ItemTypes.component_id(name)), length, encoded]
      end),
      Enum.map(removed, &Wire.varint(ItemTypes.component_id(&1)))
    ]

    check(IO.iodata_length(bytes) <= @max_bytes, :item_byte_limit)
    bytes
  end

  @doc "Whether the stack has component `name`, by default or patch (VMC-053 item predicates)."
  def has_component?(%__MODULE__{} = stack, name),
    do:
      not MapSet.member?(stack.removed, name) and
        (Map.has_key?(stack.components, name) or
           MapSet.member?(ItemTypes.defaults(stack.item_id).present, name))

  @doc "The effective value of component `name`: nil when absent, `:unknown` without a codec."
  def component(%__MODULE__{} = stack, name) do
    cond do
      MapSet.member?(stack.removed, name) ->
        nil

      Map.has_key?(stack.components, name) ->
        stack.components[name]

      true ->
        case {ItemTypes.defaults(stack.item_id).values[name], @codecs[name]} do
          {nil, _} -> nil
          {_, nil} -> :unknown
          {bytes, codec} -> elem(read_component(codec, bytes), 0)
        end
    end
  end

  @doc """
  One component value's network form, by type (`DataComponentExactPredicate`
  holds them outside a patch). Throws on an invalid or unsupported value.
  """
  def take_component(name, bytes) do
    case @codecs[name] do
      nil -> throw({:component_error, :unsupported_component})
      codec -> read_component(codec, bytes)
    end
  end

  def encode_component_value(name, value) do
    codec = @codecs[name] || throw({:component_error, :unsupported_component})
    check(valid_component?(codec, value), :invalid_component_value)
    encode_component(codec, value)
  end

  @doc "The identity key of one component value (what merging compares)."
  def component_identity(name, value), do: component_key(Map.fetch!(@codecs, name), value)

  def max_stack_size(%__MODULE__{} = stack) do
    effective(
      stack,
      "minecraft:max_stack_size",
      ItemTypes.item(stack.item_id)["max_stack_size"],
      1
    )
  end

  defp validate!(stack) do
    facts = ItemTypes.item(stack.item_id)
    check(facts != nil, :unknown_item)
    check(stack.count in 1..99, :invalid_item_count)

    check(
      map_size(stack.components) + MapSet.size(stack.removed) <= ItemTypes.component_count(),
      :component_count_limit
    )

    for {name, value} <- stack.components do
      check(ItemTypes.component_id(name) != nil, :unknown_component)
      check(not MapSet.member?(stack.removed, name), :overlapping_components)
      codec = @codecs[name]
      check(codec != nil, :unsupported_component)
      check(valid_component?(codec, value), :invalid_component_value)
    end

    for name <- stack.removed, do: check(ItemTypes.component_id(name) != nil, :unknown_component)
    maximum = max_stack_size(stack)
    check(stack.count <= maximum, :stack_size_exceeded)
    damage = effective(stack, "minecraft:max_damage", facts["max_damage"], nil)
    check(damage == nil or maximum == 1, :damageable_stack)
    :ok
  end

  defp effective(stack, name, default, absent) do
    if MapSet.member?(stack.removed, name),
      do: absent,
      else: Map.get(stack.components, name, default)
  end

  defp read_added(rest, 0, _, _, components, unsupported), do: {components, unsupported, rest}

  defp read_added(bytes, count, mode, size, components, unsupported) do
    check(size - byte_size(bytes) <= @max_bytes, :item_byte_limit)
    {id, rest} = Wire.take_varint(bytes)
    name = ItemTypes.component(id)
    check(name != nil, :unknown_component)
    check(not Map.has_key?(components, name), :duplicate_component)
    codec = @codecs[name]

    {value, rest} =
      if mode == :untrusted do
        {length, rest} = Wire.take_varint(rest)

        check(
          length <= @max_bytes and size - byte_size(rest) + length <= @max_bytes,
          :item_byte_limit
        )

        check(length <= byte_size(rest), :truncated_component)
        <<payload::binary-size(^length), tail::binary>> = rest

        if codec == nil do
          {:unsupported, tail}
        else
          {value, <<>>} = read_component(codec, payload)
          {value, tail}
        end
      else
        check(codec != nil, :unsupported_component)
        read_component(codec, rest)
      end

    unsupported = if value == :unsupported, do: [name | unsupported], else: unsupported
    read_added(rest, count - 1, mode, size, Map.put(components, name, value), unsupported)
  end

  defp read_removed(rest, 0, removed, _), do: {removed, rest}

  defp read_removed(bytes, count, removed, components) do
    {id, rest} = Wire.take_varint(bytes)
    name = ItemTypes.component(id)
    check(name != nil, :unknown_component)
    check(not MapSet.member?(removed, name), :duplicate_component)
    check(not Map.has_key?(components, name), :overlapping_components)
    read_removed(rest, count - 1, MapSet.put(removed, name), components)
  end

  defp read_component({:varint, _, _} = codec, bytes) do
    {value, rest} = Wire.take_varint(bytes)
    check(valid_component?(codec, value), :invalid_component_value)
    {value, rest}
  end

  defp read_component({:enum, _} = codec, bytes) do
    {value, rest} = Wire.take_varint(bytes)
    check(valid_component?(codec, value), :invalid_component_value)
    {value, rest}
  end

  defp read_component(:unit, rest), do: {:unit, rest}
  defp read_component(:nbt_unit, <<10, 0, rest::binary>>), do: {:unit, rest}
  defp read_component(:text, bytes), do: Codec.take(bytes)
  defp read_component(:lore, bytes), do: Codec.take_lore(bytes)
  defp read_component(:enchantments, bytes), do: Enchantments.take(bytes)
  defp read_component(:tooltip, bytes), do: TooltipDisplay.take(bytes)
  defp read_component(:food, bytes), do: FoodProperties.take(bytes)
  defp read_component(:potion_contents, bytes), do: PotionContents.take(bytes)
  defp read_component(:stew_effects, bytes), do: LootComponents.take_stew(bytes)
  defp read_component(:instrument, bytes), do: LootComponents.take_instrument(bytes)

  defp read_component({:schema, schema}, bytes), do: ComponentSchema.take(schema, bytes)

  # Persistent only: its stream form is its data form as NBT, which no client receives.
  defp read_component(:map_decorations, bytes) do
    case NBT.take(bytes) do
      {:ok, tag, rest} -> {LootComponents.decorations_from_tag(tag), rest}
      {:error, reason} -> throw({:item_error, {:nbt, reason}})
    end
  end

  defp read_component(:block_state, bytes) do
    {count, rest} = Wire.take_varint(bytes)
    check(count in 0..64, :invalid_component_value)

    Enum.reduce(1..count//1, {%{}, rest}, fn _, {map, rest} ->
      {name, rest} = Wire.take_string(rest, 32767)
      {value, rest} = Wire.take_string(rest, 32767)
      {Map.put(map, name, value), rest}
    end)
  end

  defp read_component(:nbt_compound, bytes) do
    case NBT.take(bytes) do
      {:ok, {:compound, _} = tag, rest} -> {tag, rest}
      {:ok, _, _} -> throw({:item_error, :invalid_component_value})
      {:error, reason} -> throw({:item_error, {:nbt, reason}})
    end
  end

  defp read_component(:bool, <<value, rest::binary>>) when value in [0, 1], do: {value == 1, rest}

  defp read_component(:identifier, bytes) do
    {name, rest} = Wire.take_string(bytes, 32767)

    name =
      case String.split(name, ":", parts: 2) do
        [path] -> "minecraft:" <> path
        ["", path] -> "minecraft:" <> path
        _ -> name
      end

    check(valid_component?(:identifier, name), :invalid_component_value)
    {name, rest}
  end

  defp read_component(:fraction, <<value::float-32, rest::binary>>) do
    check(valid_component?(:fraction, value), :invalid_component_value)
    {value, rest}
  end

  defp read_component(:charged_projectiles, bytes) do
    {count, rest} = Wire.take_varint(bytes)
    check(count in 0..64, :invalid_component_value)
    Enum.map_reduce(1..count//1, rest, fn _, acc -> take_template(acc) end)
  end

  defp read_component(_, _), do: throw({:item_error, :invalid_component_value})

  # `ItemStackTemplate.STREAM_CODEC`: the item, its count and its patch.
  defp take_template(bytes) do
    {id, rest} = Wire.take_varint(bytes)
    check(ItemTypes.item(id) != nil, :unknown_item)
    {count, rest} = Wire.take_varint(rest)
    check(count in 1..99, :invalid_item_count)
    {added, rest} = Wire.take_varint(rest)
    {removed, rest} = Wire.take_varint(rest)
    {components, unsupported, rest} = read_added(rest, added, :trusted, byte_size(rest), %{}, [])
    check(unsupported == [], :unsupported_component)
    {removed, rest} = read_removed(rest, removed, MapSet.new(), components)
    {%__MODULE__{item_id: id, count: count, components: components, removed: removed}, rest}
  end

  defp valid_component?({:varint, min, max}, value), do: is_integer(value) and value in min..max
  defp valid_component?({:enum, names}, value), do: is_integer(value) and is_map_key(names, value)
  defp valid_component?(:unit, value), do: value == :unit
  defp valid_component?(:nbt_unit, value), do: value == :unit
  defp valid_component?(:nbt_compound, {:compound, _} = value), do: NBT.valid?(value)
  defp valid_component?(:nbt_compound, _), do: false
  defp valid_component?(:text, value), do: Codec.valid?(value)
  defp valid_component?(:lore, value), do: Codec.valid_lore?(value)
  defp valid_component?(:enchantments, value), do: Enchantments.valid?(value)
  defp valid_component?(:tooltip, value), do: TooltipDisplay.valid?(value)
  defp valid_component?(:food, value), do: FoodProperties.valid?(value)
  defp valid_component?(:potion_contents, value), do: PotionContents.valid?(value)
  defp valid_component?(:stew_effects, value), do: LootComponents.valid_stew?(value)
  defp valid_component?(:instrument, value), do: LootComponents.valid_instrument?(value)
  defp valid_component?(:map_decorations, value), do: LootComponents.valid_decorations?(value)

  defp valid_component?({:schema, schema}, value), do: ComponentSchema.valid?(schema, value)

  defp valid_component?(:block_state, value),
    do:
      is_map(value) and map_size(value) <= 64 and
        Enum.all?(value, fn {k, v} -> is_binary(k) and is_binary(v) end)

  defp valid_component?(:bool, value), do: is_boolean(value)

  defp valid_component?(:charged_projectiles, value),
    do: is_list(value) and length(value) <= 64 and Enum.all?(value, &match?(%__MODULE__{}, &1))

  defp valid_component?(:fraction, value), do: is_float(value) and value >= 0.0 and value <= 1.0

  defp valid_component?(:identifier, value),
    do:
      is_binary(value) and byte_size(value) <= 32767 and
        Regex.match?(~r/\A[a-z0-9_.-]+:[a-z0-9_\/.\-]+\z/, value)

  defp encode_component({:varint, _, _}, value), do: Wire.varint(value)
  defp encode_component({:enum, _}, value), do: Wire.varint(value)
  defp encode_component(:unit, :unit), do: <<>>
  defp encode_component(:nbt_unit, :unit), do: <<10, 0>>
  defp encode_component(:nbt_compound, value), do: NBT.encode(value)
  defp encode_component(:text, value), do: Codec.encode(value)
  defp encode_component(:lore, value), do: Codec.encode_lore(value)
  defp encode_component(:enchantments, value), do: Enchantments.encode(value)
  defp encode_component(:tooltip, value), do: TooltipDisplay.encode(value)
  defp encode_component(:food, value), do: FoodProperties.encode(value)
  defp encode_component(:potion_contents, value), do: PotionContents.encode(value)
  defp encode_component(:stew_effects, value), do: LootComponents.encode_stew(value)
  defp encode_component(:instrument, value), do: LootComponents.encode_instrument(value)

  defp encode_component({:schema, schema}, value), do: ComponentSchema.encode(schema, value)

  defp encode_component(:map_decorations, value),
    do: NBT.encode(LootComponents.decorations_tag(value))

  defp encode_component(:block_state, value),
    do: [
      Wire.varint(map_size(value))
      | for({k, v} <- Enum.sort(value), do: [Wire.string(k), Wire.string(v)])
    ]

  defp encode_component(:bool, value), do: Wire.bool(value)
  defp encode_component(:identifier, value), do: Wire.string(value)
  defp encode_component(:fraction, value), do: <<value::float-32>>

  defp encode_component(:charged_projectiles, stacks) do
    [
      Wire.varint(length(stacks)),
      Enum.map(stacks, fn stack ->
        [count, id | patch] = encode(stack)
        [id, count | patch]
      end)
    ]
  end

  defp component_key({:schema, schema}, value), do: ComponentSchema.identity_key(schema, value)
  defp component_key(:nbt_compound, value), do: NBT.identity_key(value)
  defp component_key(:text, value), do: Codec.identity_key(value)
  defp component_key(:lore, value), do: Codec.lore_key(value)
  defp component_key(:tooltip, value), do: TooltipDisplay.identity_key(value)
  defp component_key(:potion_contents, value), do: PotionContents.identity_key(value)
  defp component_key(:map_decorations, value), do: LootComponents.decorations_key(value)
  defp component_key(codec, value), do: encode_component(codec, value) |> IO.iodata_to_binary()
  defp check(true, _), do: :ok
  defp check(false, reason), do: throw({:item_error, reason})
end
