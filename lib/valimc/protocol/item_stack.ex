defmodule Valimc.Protocol.ItemStack do
  @moduledoc "Pure bounded 26.3 stacks. Unsupported structured patches never become accepted data."
  alias Valimc.Protocol.{ItemTypes, NBT, Wire}
  defstruct [:item_id, count: 1, components: %{}, removed: MapSet.new()]

  @max_bytes 65_536
  @codecs %{
    "minecraft:custom_data" => :nbt_compound,
    "minecraft:max_stack_size" => {:varint, 1, 99},
    "minecraft:max_damage" => {:varint, 1, 2_147_483_647},
    "minecraft:damage" => {:varint, 0, 2_147_483_647},
    "minecraft:repair_cost" => {:varint, 0, 2_147_483_647},
    "minecraft:rarity" => {:varint, 0, 3},
    "minecraft:unbreakable" => :unit,
    "minecraft:creative_slot_lock" => :unit,
    "minecraft:intangible_projectile" => :nbt_unit,
    "minecraft:enchantment_glint_override" => :bool,
    "minecraft:item_model" => :identifier,
    "minecraft:tooltip_style" => :identifier,
    "minecraft:minimum_attack_charge" => :fraction
  }

  def new(name, count \\ 1), do: %__MODULE__{item_id: ItemTypes.id(name), count: count}
  def supported_components, do: Map.keys(@codecs)

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
  end

  def encode(stack, mode \\ :trusted)
  def encode(nil, mode) when mode in [:trusted, :untrusted], do: <<0>>

  def encode(%__MODULE__{} = stack, mode) when mode in [:trusted, :untrusted] do
    validate!(stack)
    added = Enum.sort_by(stack.components, fn {name, _} -> ItemTypes.component_id(name) end)
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

  defp read_component(:unit, rest), do: {:unit, rest}
  defp read_component(:nbt_unit, <<10, 0, rest::binary>>), do: {:unit, rest}

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

  defp read_component(_, _), do: throw({:item_error, :invalid_component_value})
  defp valid_component?({:varint, min, max}, value), do: is_integer(value) and value in min..max
  defp valid_component?(:unit, value), do: value == :unit
  defp valid_component?(:nbt_unit, value), do: value == :unit
  defp valid_component?(:nbt_compound, {:compound, _} = value), do: NBT.valid?(value)
  defp valid_component?(:nbt_compound, _), do: false
  defp valid_component?(:bool, value), do: is_boolean(value)
  defp valid_component?(:fraction, value), do: is_float(value) and value >= 0.0 and value <= 1.0

  defp valid_component?(:identifier, value),
    do:
      is_binary(value) and byte_size(value) <= 32767 and
        Regex.match?(~r/\A[a-z0-9_.-]+:[a-z0-9_\/.\-]+\z/, value)

  defp encode_component({:varint, _, _}, value), do: Wire.varint(value)
  defp encode_component(:unit, :unit), do: <<>>
  defp encode_component(:nbt_unit, :unit), do: <<10, 0>>
  defp encode_component(:nbt_compound, value), do: NBT.encode(value)
  defp encode_component(:bool, value), do: Wire.bool(value)
  defp encode_component(:identifier, value), do: Wire.string(value)
  defp encode_component(:fraction, value), do: <<value::float-32>>
  defp check(true, _), do: :ok
  defp check(false, reason), do: throw({:item_error, reason})
end
