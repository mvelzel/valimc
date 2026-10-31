defmodule Valimc.Protocol.ComponentSchema do
  @moduledoc """
  Declarative item component codecs (VMC-004b4).

  A schema describes one component value once; this module reads and writes it
  in both of vanilla's formats, the network stream (`take/2`, `encode/2`) and
  the data form, NBT as world files and commands hold it (`from_tag/2`,
  `to_tag/2`), validates it (`valid?/2`) and gives the identity key that stack
  merging compares (`identity_key/2`). It is pure; every read is bounded by its
  input (a list's count never exceeds the bytes left) and by explicit limits.

  Values are plain data shaped like the data form: a record is a map keyed by
  field name with its defaults filled in, an enum value or a registry entry is
  its name, a holder set is `{:tag, id}` or a list of entries, an absent
  optional is `nil` and an `either` is `{:left, v}` or `{:right, v}`. A finite
  float is an Elixir float; a non-finite one keeps its bits as
  `{:float_bits, bits}` (or `{:double_bits, bits}`).

  Schemas:

    * `:bool`, `:varint`, `:int`, `:long`, `:float`, `:double`
    * `:unsigned_byte`: a VarInt of 0..255 on the network, a signed byte
      tag in the data form (`ExtraCodecs.UNSIGNED_BYTE`)
    * `{:range, schema, min, max}`: bounds inclusive; `{:gt, x}` excludes `x`,
      `nil` leaves a side open
    * `{:string, max}`: at most `max` UTF-16 units, as Java counts them
    * `:identifier`, `:text`, `:rgb`, `:block_pos`, `:unit`
    * `{:enum, name}`: a generated enum (`ComponentTypes.enum/1`)
    * `{:registry, registry}`: an entry by network id (also a plain holder)
    * `{:holder, registry}`: an entry by id + 1; an inline value (id 0) is refused
    * `{:holder_set, registry}`: a tag or a list of entries
    * `{:resource_key, registry}`: an identifier naming an entry of a registry
      the client need not hold
    * `{:optional, schema}`, `{:list, schema, max}`, `{:either, left, right}`
    * `{:record, fields}`: fields are `{name, schema}` (required, or absent
      when the schema is optional) or `{name, schema, default}`
    * `{:nbt, schema}`: a persistent-only value, whose stream form is its data
      form as network NBT
    * `{:dispatch, type_schema, cases}`: a type, then the fields `cases` lists
      for it; the data form is one compound with a `type` field
    * `{:map, key, value, max}`: `{key, value}` pairs, a list on the network and
      a compound in the data form
    * `{:compact_list, schema}`: a list whose data form writes one entry alone
    * `:mob_effect`, `:effect_details`: `MobEffectInstance` and its details
    * `:components`: exact component values (`DataComponentExactPredicate`),
      `{name, value}` pairs through `ItemStack`'s and `ItemData`'s codecs
    * `:no_predicates`: partial component predicates, accepted only empty
    * `:unsupported`: a branch ValiMC refuses (a block predicate's NBT)
    * `:template`: an item stack template, an `ItemStack` of 1..99 with its own
      patch; templates nest at most 16 deep
    * `:container`: a container's slots, `nil` for an empty one; the data form
      lists the filled ones by slot
    * `{:contents, schema}`: held stacks that must fit their own items
      (`ItemStack.validateContainedItemSizes`)
    * `:uuid` (16 bytes; four ints in the data form), `:player_name`
    * `{:typed_data, type_schema}`: a type and its NBT compound
      (`TypedEntityData`); the data form puts the type under `id`
    * `{:fixed_list, schema, n}`: exactly `n` entries, without a count on the
      network
    * `{:filterable, schema}`: `%{"raw" => v, "filtered" => v | nil}`; the
      data form also reads a bare value
    * `:profile`: `ResolvableProfile`, `"profile"` holding a complete game
      profile `{:left, ...}` or a partial one `{:right, ...}`, beside the
      skin patch; the data form also reads a bare player name
    * `:int_bounds`: `MinMaxBounds.Ints` as `%{"min" => n, "max" => n}`
    * `:block_properties`: a debug stick's block => property name pairs

  A record field `{name, schema, {:present, default}}` reads its default when
  absent and is always written (`optionalAlwaysPresentFieldOf`).
  """
  import Bitwise
  alias Valimc.Data.{BuiltinRegistries, ComponentTypes, NBT}
  alias Valimc.Protocol.{ItemData, ItemStack, ItemTypes, Wire}
  alias Valimc.Text.Codec, as: Text

  @max_string 32767

  # `MobEffectInstance.Details`: an absent `show_icon` follows `show_particles`
  # in the data form, which always writes it.
  @details [
    {"amplifier", :amplifier, 0},
    {"duration", :varint, 0},
    {"ambient", :bool, false},
    {"show_particles", :bool, true},
    {"show_icon", :bool},
    {"hidden_effect", {:optional, :effect_details}}
  ]
  @mob_effect [{"id", {:registry, "minecraft:mob_effect"}} | @details]
  @max_nesting 16
  @nesting {__MODULE__, :nesting}
  @property {:record,
             [
               {"name", {:string, 64}},
               {"value", {:string, 32767}},
               {"signature", {:optional, {:string, 1024}}}
             ]}
  @game_profile {:record,
                 [{"id", :uuid}, {"name", :player_name}, {"properties", :properties, []}]}
  @partial_profile {:record,
                    [
                      {"name", {:optional, :player_name}},
                      {"id", {:optional, :uuid}},
                      {"properties", :properties, []}
                    ]}
  @skin {:record,
         [
           {"texture", {:optional, :identifier}},
           {"cape", {:optional, :identifier}},
           {"elytra", {:optional, :identifier}},
           {"model", {:optional, :player_model}}
         ]}
  @slots {:list, {:optional, :template}, 256}
  @slot_entries {:list, {:record, [{"slot", {:range, :int, 0, 255}}, {"item", :template}]}, 256}

  ## Network stream

  @doc "Read one value; `{value, rest}`. Throws `{:component_error, reason}`."
  def take(schema, bytes)

  def take(:bool, <<value, rest::binary>>) when value in [0, 1], do: {value == 1, rest}

  def take(:varint, bytes) do
    case Wire.read_varint(bytes) do
      {:ok, value, rest} -> {signed32(value), rest}
      _ -> fail(:invalid_varint)
    end
  end

  def take(:unsigned_byte, bytes) do
    {value, rest} = take(:varint, bytes)
    check(value in 0..255, :out_of_range)
    {value, rest}
  end

  def take(:int, <<value::signed-32, rest::binary>>), do: {value, rest}
  def take(:long, <<value::signed-64, rest::binary>>), do: {value, rest}
  def take(:rgb, <<value::signed-32, rest::binary>>), do: {value, rest}
  def take(:float, <<bits::32, rest::binary>>), do: {float32(bits), rest}
  def take(:double, <<bits::64, rest::binary>>), do: {float64(bits), rest}

  def take(:block_pos, <<x::signed-26, z::signed-26, y::signed-12, rest::binary>>),
    do: {{x, y, z}, rest}

  def take({:range, schema, min, max}, bytes) do
    {value, rest} = take(schema, bytes)
    check(in_range?(value, min, max), :out_of_range)
    {value, rest}
  end

  def take({:string, max}, bytes), do: take_string(bytes, max)
  def take(:identifier, bytes), do: bytes |> take_string(@max_string) |> identifier()
  def take(:text, bytes), do: Text.take(bytes)
  def take(:unit, bytes), do: {:unit, bytes}

  def take({:enum, name}, bytes) do
    {id, rest} = take(:varint, bytes)
    {Map.get(ComponentTypes.enum(name), id) || fail(:unknown_enum), rest}
  end

  def take({:registry, registry}, bytes) do
    {id, rest} = take(:varint, bytes)
    {registry_name(registry, id) || fail(:unknown_registry_id), rest}
  end

  def take({:holder, registry}, bytes) do
    case take(:varint, bytes) do
      {0, _} -> fail(:direct_holder)
      {id, rest} -> {registry_name(registry, id - 1) || fail(:unknown_registry_id), rest}
    end
  end

  def take({:holder_set, registry}, bytes) do
    case take(:varint, bytes) do
      {0, rest} ->
        {tag, rest} = take(:identifier, rest)
        check(tag?(registry, tag), :unknown_tag)
        {{:tag, tag}, rest}

      {count, rest} ->
        take_list({:registry, registry}, count - 1, rest)
    end
  end

  def take({:resource_key, _registry}, bytes), do: take(:identifier, bytes)

  def take({:optional, schema}, bytes) do
    case take(:bool, bytes) do
      {false, rest} -> {nil, rest}
      {true, rest} -> take(schema, rest)
    end
  end

  def take({:list, schema, max}, bytes) do
    {count, rest} = take(:varint, bytes)
    check(count >= 0 and (max == :infinity or count <= max), :list_too_long)
    take_list(schema, count, rest)
  end

  def take({:either, left, right}, bytes) do
    case take(:bool, bytes) do
      {true, rest} -> with({value, rest} <- take(left, rest), do: {{:left, value}, rest})
      {false, rest} -> with({value, rest} <- take(right, rest), do: {{:right, value}, rest})
    end
  end

  def take({:record, fields}, bytes) do
    Enum.reduce(fields, {%{}, bytes}, fn field, {record, rest} ->
      {value, rest} = take(field_schema(field), rest)
      {Map.put(record, field_name(field), value), rest}
    end)
  end

  def take({:nbt, schema}, bytes) do
    case NBT.take(bytes) do
      {:ok, tag, rest} -> {from_tag(schema, tag), rest}
      {:error, reason} -> fail({:nbt, reason})
    end
  end

  def take({:dispatch, type_schema, cases}, bytes) do
    {type, rest} = take(type_schema, bytes)
    {record, rest} = take({:record, case_fields(cases, type)}, rest)
    {Map.put(record, "type", type), rest}
  end

  def take({:map, key, value, max}, bytes),
    do: take({:list, {:record, [{0, key}, {1, value}]}, max}, bytes) |> pairs()

  def take({:compact_list, schema}, bytes), do: take({:list, schema, :infinity}, bytes)
  def take(:amplifier, bytes), do: take(:varint, bytes)
  def take(:effect_details, bytes), do: take({:record, @details}, bytes)
  def take(:mob_effect, bytes), do: take({:record, @mob_effect}, bytes)

  def take(:components, bytes) do
    {count, rest} = take(:varint, bytes)
    check(count >= 0 and count <= byte_size(rest), :list_too_long)

    {pairs, rest} =
      Enum.reduce(1..count//1, {[], rest}, fn _, {pairs, rest} ->
        {id, rest} = take(:varint, rest)
        name = ItemTypes.component(id) || fail(:unknown_component)
        {value, rest} = ItemStack.take_component(name, rest)
        {[{name, value} | pairs], rest}
      end)

    {Enum.reverse(pairs), rest}
  end

  def take(:no_predicates, bytes) do
    case take(:varint, bytes) do
      {0, rest} -> {[], rest}
      _ -> fail(:unsupported_predicate)
    end
  end

  def take(:unsupported, _bytes), do: fail(:unsupported_predicate)
  def take(:template, bytes), do: nested(fn -> ItemStack.take_template(bytes) end)
  def take(:uuid, <<uuid::binary-16, rest::binary>>), do: {uuid, rest}

  def take(:player_name, bytes),
    do: bytes |> take_string(16) |> tap(&check(player_name?(elem(&1, 0)), :invalid_player_name))

  def take(:player_model, bytes) do
    {slim, rest} = take(:bool, bytes)
    {if(slim, do: "slim", else: "wide"), rest}
  end

  def take(:properties, bytes), do: take({:list, @property, 16}, bytes)

  def take({:typed_data, type_schema}, bytes) do
    {type, rest} = take(type_schema, bytes)
    {data, rest} = take_compound(rest)
    {%{"id" => type, "data" => strip_id(data)}, rest}
  end

  # `ByteBufCodecs.fixedSizeList`: the entries alone, no count.
  def take({:fixed_list, schema, n}, bytes), do: take_list(schema, n, bytes)

  def take({:filterable, schema}, bytes), do: take(filterable(schema), bytes)

  def take(:profile, bytes) do
    {profile, rest} = take({:either, @game_profile, @partial_profile}, bytes)
    {skin, rest} = take(@skin, rest)
    {Map.put(skin, "profile", profile), rest}
  end

  def take(:int_bounds, bytes),
    do: take({:record, [{"min", {:optional, :int}}, {"max", {:optional, :int}}]}, bytes)

  def take(:container, bytes), do: take(@slots, bytes)

  def take({:contents, schema}, bytes),
    do: schema |> take(bytes) |> tap(fn {stacks, _} -> fits!(stacks) end)

  def take(_schema, _bytes), do: fail(:malformed)

  defp pairs({records, rest}), do: {Enum.map(records, &{&1[0], &1[1]}), rest}

  defp case_fields(cases, type), do: Map.get(cases, type) || fail(:unknown_type)

  # Each element takes at least one byte, so a count beyond the input is malformed.
  defp take_list(schema, count, bytes) do
    check(count >= 0 and count <= byte_size(bytes), :list_too_long)

    {values, rest} =
      Enum.reduce(1..count//1, {[], bytes}, fn _, {values, rest} ->
        {value, rest} = take(schema, rest)
        {[value | values], rest}
      end)

    {Enum.reverse(values), rest}
  end

  @doc "Write one value as iodata. Throws `{:component_error, reason}` for an invalid value."
  def encode(schema, value)

  def encode(:bool, value) when is_boolean(value), do: Wire.bool(value)
  def encode(:unsigned_byte, value) when value in 0..255, do: Wire.varint(value)
  def encode(:varint, value) when is_integer(value), do: Wire.varint(value)

  def encode(kind, value) when kind in [:int, :rgb] and is_integer(value),
    do: <<value::signed-32>>

  def encode(:long, value) when is_integer(value), do: <<value::signed-64>>
  def encode(:float, value), do: <<float32_bits(value)::32>>
  def encode(:double, value), do: <<float64_bits(value)::64>>

  def encode(:block_pos, {x, y, z}),
    do: <<x &&& 0x3FFFFFF::26, z &&& 0x3FFFFFF::26, y &&& 0xFFF::12>>

  def encode({:range, schema, min, max}, value) do
    check(in_range?(value, min, max), :out_of_range)
    encode(schema, value)
  end

  def encode({:string, max}, value) do
    check(valid_string?(value, max), :invalid_string)
    Wire.string(value)
  end

  def encode(:identifier, value) do
    check(identifier?(value), :invalid_identifier)
    Wire.string(value)
  end

  def encode(:text, value) do
    check(Text.valid?(value), :invalid_text)
    Text.encode(value)
  end

  def encode(:unit, :unit), do: []

  def encode({:enum, name}, value),
    do: Wire.varint(enum_id(name, value) || fail(:unknown_enum))

  def encode({:registry, registry}, value),
    do: Wire.varint(registry_id(registry, value) || fail(:unknown_registry_entry))

  def encode({:holder, registry}, value),
    do: Wire.varint((registry_id(registry, value) || fail(:unknown_registry_entry)) + 1)

  def encode({:holder_set, registry}, {:tag, tag}) do
    check(tag?(registry, tag), :unknown_tag)
    [Wire.varint(0), Wire.string(tag)]
  end

  def encode({:holder_set, registry}, values) when is_list(values),
    do: [Wire.varint(length(values) + 1), Enum.map(values, &encode({:registry, registry}, &1))]

  def encode({:resource_key, _}, value), do: encode(:identifier, value)
  def encode({:optional, _}, nil), do: Wire.bool(false)
  def encode({:optional, schema}, value), do: [Wire.bool(true), encode(schema, value)]

  def encode({:list, schema, max}, values) when is_list(values) do
    check(max == :infinity or length(values) <= max, :list_too_long)
    [Wire.varint(length(values)), Enum.map(values, &encode(schema, &1))]
  end

  def encode({:either, left, _}, {:left, value}), do: [Wire.bool(true), encode(left, value)]
  def encode({:either, _, right}, {:right, value}), do: [Wire.bool(false), encode(right, value)]

  def encode({:record, fields}, record) when is_map(record),
    do: Enum.map(fields, &encode(field_schema(&1), Map.fetch!(record, field_name(&1))))

  def encode({:nbt, schema}, value), do: NBT.encode(to_tag(schema, value))

  def encode({:dispatch, type_schema, cases}, %{"type" => type} = value),
    do: [encode(type_schema, type), encode({:record, case_fields(cases, type)}, value)]

  def encode({:map, key, value, max}, pairs) when is_list(pairs),
    do:
      encode(
        {:list, {:record, [{0, key}, {1, value}]}, max},
        Enum.map(pairs, fn {k, v} -> %{0 => k, 1 => v} end)
      )

  def encode({:compact_list, schema}, values), do: encode({:list, schema, :infinity}, values)
  def encode(:amplifier, value), do: encode(:varint, value)
  def encode(:effect_details, value), do: encode({:record, @details}, value)
  def encode(:mob_effect, value), do: encode({:record, @mob_effect}, value)

  def encode(:components, pairs) when is_list(pairs) do
    [
      Wire.varint(length(pairs)),
      Enum.map(pairs, fn {name, value} ->
        [
          Wire.varint(ItemTypes.component_id(name) || fail(:unknown_component)),
          ItemStack.encode_component_value(name, value)
        ]
      end)
    ]
  end

  def encode(:no_predicates, []), do: Wire.varint(0)

  def encode(:template, %ItemStack{} = stack),
    do: nested(fn -> ItemStack.encode_template(stack) end)

  def encode(:container, slots), do: encode(@slots, slots)
  def encode(:uuid, <<_::binary-16>> = uuid), do: uuid

  def encode(:player_name, value) do
    check(player_name?(value), :invalid_player_name)
    Wire.string(value)
  end

  def encode(:player_model, value) when value in ["slim", "wide"], do: Wire.bool(value == "slim")
  def encode(:properties, values), do: encode({:list, @property, 16}, values)

  def encode({:typed_data, type_schema}, %{"id" => type, "data" => {:compound, _} = data}),
    do: [encode(type_schema, type), NBT.encode(strip_id(data))]

  def encode({:fixed_list, schema, n}, values) when length(values) == n,
    do: Enum.map(values, &encode(schema, &1))

  def encode({:filterable, schema}, value), do: encode(filterable(schema), value)

  def encode(:profile, %{"profile" => profile} = value),
    do: [encode({:either, @game_profile, @partial_profile}, profile), encode(@skin, value)]

  def encode({:contents, schema}, stacks) do
    fits!(stacks)
    encode(schema, stacks)
  end

  def encode(_schema, _value), do: fail(:invalid_value)

  @doc "Whether `value` is a valid value of `schema`."
  def valid?(schema, value) do
    _ = encode(schema, value)
    true
  catch
    {:component_error, _} -> false
  end

  @doc """
  Count-independent comparison key: the canonical stream encoding, with every
  NaN as Java's canonical NaN (`Float.equals`) and map entries sorted.
  """
  def identity_key(schema, value),
    do: schema |> encode(canonical(value)) |> IO.iodata_to_binary()

  defp canonical({:float_bits, bits}) when (bits &&& 0x7FFFFF) != 0, do: {:float_bits, 0x7FC00000}

  defp canonical({:double_bits, bits}) when (bits &&& 0xFFFFFFFFFFFFF) != 0,
    do: {:double_bits, 0x7FF8000000000000}

  # Map entries (`{:map, ...}`, `:components`) compare without their order, as
  # their data form, a compound, has none.
  defp canonical(values) when is_list(values) do
    values = Enum.map(values, &canonical/1)

    if values != [] and Enum.all?(values, &match?({key, _} when is_binary(key), &1)),
      do: Enum.sort(values),
      else: values
  end

  # A template compares its patch as written, as `ItemStackTemplate.equals` does.
  defp canonical(%ItemStack{} = stack),
    do: %{stack | components: Map.new(stack.components, fn {k, v} -> {k, canonical(v)} end)}

  defp canonical(%{} = map), do: Map.new(map, fn {k, v} -> {k, canonical(v)} end)
  defp canonical({tag, value}) when tag in [:left, :right], do: {tag, canonical(value)}
  defp canonical({key, value}) when is_binary(key), do: {key, canonical(value)}
  defp canonical(value), do: value

  ## Data form (NBT through vanilla's codecs)

  @doc "Read the data form; throws `{:component_error, reason}`."
  def from_tag(schema, tag)

  def from_tag(:bool, tag), do: number(tag) != 0
  def from_tag(:unsigned_byte, tag), do: int(tag) &&& 0xFF
  def from_tag(kind, tag) when kind in [:varint, :int], do: int(tag)
  def from_tag(:long, tag), do: long(tag)

  def from_tag(:float, {:float, <<bits::32>>}), do: float32(bits)
  def from_tag(:float, tag), do: tag |> number() |> Valimc.Data.Float32.round()
  def from_tag(:double, {:double, <<bits::64>>}), do: float64(bits)
  def from_tag(:double, tag), do: number(tag) * 1.0

  # `ExtraCodecs.RGB_COLOR_CODEC`: an int or three channel floats.
  def from_tag(:rgb, {:list, _} = list) do
    case Enum.map(NBT.items(list), &number/1) do
      [r, g, b] ->
        Bitwise.bor(0xFF000000, channel(r) <<< 16 ||| channel(g) <<< 8 ||| channel(b))
        |> signed32()

      _ ->
        fail(:invalid_color)
    end
  end

  def from_tag(:rgb, tag), do: int(tag)

  def from_tag(:block_pos, {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>}),
    do: {x, y, z}

  def from_tag({:range, schema, min, max}, tag) do
    value = from_tag(schema, tag)
    check(in_range?(value, min, max), :out_of_range)
    value
  end

  def from_tag({:string, max}, {:string, value}) do
    check(valid_string?(value, max), :invalid_string)
    value
  end

  def from_tag(:identifier, {:string, value}), do: elem(identifier({value, <<>>}), 0)
  def from_tag(:text, tag), do: tag |> tap(&check(Text.valid?(&1), :invalid_text))
  def from_tag(:unit, {:compound, _}), do: :unit

  def from_tag({:enum, name}, {:string, value}) do
    check(enum_id(name, value) != nil, :unknown_enum)
    value
  end

  def from_tag({kind, registry}, {:string, _} = tag) when kind in [:registry, :holder] do
    id = from_tag(:identifier, tag)
    check(registry_id(registry, id) != nil, :unknown_registry_entry)
    id
  end

  def from_tag({:holder_set, registry}, {:string, "#" <> tag}) do
    tag = from_tag(:identifier, {:string, tag})
    check(tag?(registry, tag), :unknown_tag)
    {:tag, tag}
  end

  def from_tag({:holder_set, registry}, {:string, _} = tag),
    do: [from_tag({:registry, registry}, tag)]

  def from_tag({:holder_set, registry}, {:list, _} = list),
    do: Enum.map(NBT.items(list), &from_tag({:registry, registry}, &1))

  def from_tag({:resource_key, _}, tag), do: from_tag(:identifier, tag)
  def from_tag({:optional, schema}, tag), do: from_tag(schema, tag)

  def from_tag({:list, schema, max}, tag) do
    values = Enum.map(items(tag), &from_tag(schema, &1))
    check(max == :infinity or length(values) <= max, :list_too_long)
    values
  end

  # `Codec.either`: the left codec first, then the right.
  def from_tag({:either, left, right}, tag) do
    {:left, from_tag(left, tag)}
  catch
    {:component_error, _} -> {:right, from_tag(right, tag)}
  end

  def from_tag({:record, fields}, {:compound, values}) do
    Map.new(fields, fn field ->
      name = field_name(field)

      value =
        case {values, field} do
          {%{^name => tag}, _} -> from_tag(field_schema(field), tag)
          {_, {_, _, {:present, default}}} -> default
          {_, {_, _, default}} -> default
          {_, {_, {:optional, _}}} -> nil
          _ -> fail({:missing_field, name})
        end

      {name, value}
    end)
  end

  def from_tag({:nbt, schema}, tag), do: from_tag(schema, tag)

  def from_tag({:dispatch, type_schema, cases}, {:compound, %{"type" => type} = values}) do
    type = from_tag(type_schema, type)
    {:record, case_fields(cases, type)} |> from_tag({:compound, values}) |> Map.put("type", type)
  end

  def from_tag({:map, key, value, max}, {:compound, values}) do
    check(max == :infinity or map_size(values) <= max, :list_too_long)

    values
    |> Enum.sort()
    |> Enum.map(fn {k, v} -> {from_tag(key, {:string, k}), from_tag(value, v)} end)
  end

  def from_tag({:compact_list, schema}, {:list, _} = list) do
    values = Enum.map(NBT.items(list), &from_tag(schema, &1))
    check(values != [], :empty_list)
    values
  end

  def from_tag({:compact_list, schema}, tag), do: [from_tag(schema, tag)]
  def from_tag(:amplifier, tag), do: from_tag(:unsigned_byte, tag)
  def from_tag(:effect_details, tag), do: from_tag({:record, @details}, show_icon(tag))
  def from_tag(:mob_effect, tag), do: from_tag({:record, @mob_effect}, show_icon(tag))

  def from_tag(:components, {:compound, values}) do
    values
    |> Enum.sort()
    |> Enum.map(fn {name, tag} ->
      name = from_tag(:identifier, {:string, name})
      check(ItemTypes.component_id(name) != nil, :unknown_component)
      {name, ItemData.component_value(name, tag)}
    end)
  end

  def from_tag(:no_predicates, {:compound, values}) when map_size(values) == 0, do: []
  def from_tag(:template, tag), do: nested(fn -> ItemData.template(tag) end)

  # `ItemContainerContents.fromSlots`: slots up to the highest filled one.
  def from_tag(:container, tag) do
    case from_tag(@slot_entries, tag) do
      [] ->
        []

      entries ->
        filled = Map.new(entries, &{&1["slot"], &1["item"]})
        for slot <- 0..Enum.max(Map.keys(filled)), do: filled[slot]
    end
  end

  def from_tag({:contents, schema}, tag), do: schema |> from_tag(tag) |> tap(&fits!/1)

  def from_tag(:uuid, {:int_array, <<_::binary-16>> = uuid}), do: uuid

  def from_tag(:player_name, {:string, value}) do
    check(player_name?(value), :invalid_player_name)
    value
  end

  def from_tag(:player_model, {:string, value}) when value in ["slim", "wide"], do: value

  # `ExtraCodecs.PROPERTY_MAP`: name => values, or a list of properties.
  def from_tag(:properties, {:compound, values}) do
    check(map_size(values) <= 16, :list_too_long)

    for {name, list} <- Enum.sort(values), {:string, value} <- items(list) do
      check(valid_string?(name, 64) and valid_string?(value, 32767), :invalid_string)
      %{"name" => name, "value" => value, "signature" => nil}
    end
  end

  def from_tag(:properties, tag), do: from_tag({:list, @property, 16}, tag)

  def from_tag({:typed_data, type_schema}, {:compound, %{"id" => type} = values}),
    do: %{"id" => from_tag(type_schema, type), "data" => {:compound, Map.delete(values, "id")}}

  def from_tag({:fixed_list, schema, n}, tag) do
    values = from_tag({:list, schema, n}, tag)
    check(length(values) == n, :wrong_list_size)
    values
  end

  # `Filterable.codec`: `{raw, filtered}`, or the bare value.
  def from_tag({:filterable, schema}, tag) do
    from_tag(filterable(schema), tag)
  catch
    {:component_error, _} -> %{"raw" => from_tag(schema, tag), "filtered" => nil}
  end

  def from_tag(:profile, {:string, name}),
    do: from_tag(:profile, {:compound, %{"name" => {:string, name}}})

  def from_tag(:profile, {:compound, _} = tag) do
    profile =
      case from_tag({:either, @game_profile, @partial_profile}, tag) do
        {:right, partial} = right ->
          # A partial profile holds at least a name or an id.
          check(
            partial["name"] != nil or partial["id"] != nil or partial["properties"] != [],
            :empty_profile
          )

          right

        left ->
          left
      end

    Map.put(from_tag(@skin, tag), "profile", profile)
  end

  def from_tag(:int_bounds, {:compound, _} = tag),
    do: from_tag({:record, [{"min", {:optional, :int}}, {"max", {:optional, :int}}]}, tag)

  def from_tag(:int_bounds, tag), do: tag |> int() |> then(&%{"min" => &1, "max" => &1})

  def from_tag(:block_properties, {:compound, values}) do
    for {block, {:string, property}} <- Enum.sort(values) do
      block = from_tag({:registry, "minecraft:block"}, {:string, block})
      "minecraft:" <> name = block
      properties = name |> Valimc.Data.Blocks.default_state() |> Valimc.Data.Blocks.properties()
      check(List.keymember?(properties, property, 0), :unknown_property)
      {block, property}
    end
  end

  def from_tag(_schema, _tag), do: fail(:invalid_tag)

  defp show_icon({:compound, %{"show_icon" => _}} = tag), do: tag

  defp show_icon({:compound, values}),
    do: {:compound, Map.put(values, "show_icon", Map.get(values, "show_particles", {:byte, 1}))}

  defp show_icon(tag), do: tag

  @doc "Write the data form as vanilla's codecs write it (defaults omitted)."
  def to_tag(schema, value)

  def to_tag(:bool, value) when is_boolean(value), do: {:byte, if(value, do: 1, else: 0)}

  def to_tag(:unsigned_byte, value) when value in 0..255,
    do: {:byte, if(value > 127, do: value - 256, else: value)}

  def to_tag(kind, value) when kind in [:varint, :int, :rgb] and is_integer(value),
    do: {:int, value}

  def to_tag(:long, value) when is_integer(value), do: {:long, value}
  def to_tag(:float, value), do: {:float, <<float32_bits(value)::32>>}
  def to_tag(:double, value), do: {:double, <<float64_bits(value)::64>>}

  def to_tag(:block_pos, {x, y, z}),
    do: {:int_array, <<x::signed-32, y::signed-32, z::signed-32>>}

  def to_tag({:range, schema, min, max}, value) do
    check(in_range?(value, min, max), :out_of_range)
    to_tag(schema, value)
  end

  def to_tag({:string, max}, value) do
    check(valid_string?(value, max), :invalid_string)
    {:string, value}
  end

  def to_tag(:identifier, value) do
    check(identifier?(value), :invalid_identifier)
    {:string, value}
  end

  def to_tag(:text, value), do: value
  def to_tag(:unit, :unit), do: {:compound, %{}}
  def to_tag({:enum, _}, value) when is_binary(value), do: {:string, value}

  def to_tag({kind, _}, value) when kind in [:registry, :holder, :resource_key],
    do: to_tag(:identifier, value)

  def to_tag({:holder_set, _}, {:tag, tag}), do: {:string, "#" <> tag}

  # `ExtraCodecs.compactListCodec`: one entry is written alone.
  def to_tag({:holder_set, registry}, [value]), do: to_tag({:registry, registry}, value)

  def to_tag({:holder_set, registry}, values) when is_list(values),
    do: NBT.list(Enum.map(values, &to_tag({:registry, registry}, &1)))

  def to_tag({:optional, schema}, value), do: to_tag(schema, value)

  def to_tag({:list, schema, _}, values) when is_list(values),
    do: NBT.list(Enum.map(values, &to_tag(schema, &1)))

  def to_tag({:either, left, _}, {:left, value}), do: to_tag(left, value)
  def to_tag({:either, _, right}, {:right, value}), do: to_tag(right, value)

  def to_tag({:record, fields}, record) when is_map(record) do
    fields =
      for field <- fields,
          {name, value} = {field_name(field), Map.fetch!(record, field_name(field))},
          not omitted?(field, value),
          into: %{},
          do: {name, to_tag(field_schema(field), value)}

    {:compound, fields}
  end

  def to_tag({:nbt, schema}, value), do: to_tag(schema, value)

  def to_tag({:dispatch, type_schema, cases}, %{"type" => type} = value) do
    {:compound, fields} = to_tag({:record, case_fields(cases, type)}, value)
    {:compound, Map.put(fields, "type", to_tag(type_schema, type))}
  end

  def to_tag({:map, key, value, _}, pairs) when is_list(pairs) do
    {:compound,
     Map.new(pairs, fn {k, v} ->
       {:string, k} = to_tag(key, k)
       {k, to_tag(value, v)}
     end)}
  end

  def to_tag({:compact_list, schema}, [value]), do: to_tag(schema, value)
  def to_tag({:compact_list, schema}, values), do: to_tag({:list, schema, :infinity}, values)
  def to_tag(:amplifier, value), do: to_tag(:unsigned_byte, value)
  def to_tag(:effect_details, value), do: to_tag({:record, @details}, value)
  def to_tag(:mob_effect, value), do: to_tag({:record, @mob_effect}, value)

  def to_tag(:components, pairs) when is_list(pairs),
    do:
      {:compound,
       Map.new(pairs, fn {name, value} -> {name, ItemData.component_tag(name, value)} end)}

  def to_tag(:no_predicates, []), do: {:compound, %{}}
  def to_tag(:template, %ItemStack{} = stack), do: nested(fn -> ItemData.template_tag(stack) end)

  def to_tag(:container, slots) when is_list(slots) do
    entries =
      for {stack, slot} <- Enum.with_index(slots),
          stack != nil,
          do: %{"slot" => slot, "item" => stack}

    to_tag(@slot_entries, entries)
  end

  def to_tag(:uuid, <<_::binary-16>> = uuid), do: {:int_array, uuid}
  def to_tag(:player_name, value), do: {:string, value}
  def to_tag(:player_model, value) when value in ["slim", "wide"], do: {:string, value}
  def to_tag(:properties, values), do: to_tag({:list, @property, 16}, values)

  def to_tag({:typed_data, type_schema}, %{"id" => type, "data" => {:compound, values}}),
    do: {:compound, Map.put(values, "id", to_tag(type_schema, type))}

  def to_tag({:fixed_list, schema, n}, values) when length(values) == n,
    do: to_tag({:list, schema, n}, values)

  def to_tag({:filterable, schema}, value), do: to_tag(filterable(schema), value)

  def to_tag(:profile, %{"profile" => profile} = value) do
    {:compound, fields} = to_tag({:either, @game_profile, @partial_profile}, profile)
    {:compound, skin} = to_tag(@skin, value)
    {:compound, Map.merge(fields, skin)}
  end

  # A point is written as one number.
  def to_tag(:int_bounds, %{"min" => n, "max" => n}) when is_integer(n), do: {:int, n}

  def to_tag(:int_bounds, value),
    do: to_tag({:record, [{"min", {:optional, :int}}, {"max", {:optional, :int}}]}, value)

  def to_tag(:block_properties, pairs) when is_list(pairs),
    do: {:compound, Map.new(pairs, fn {block, property} -> {block, {:string, property}} end)}

  def to_tag({:contents, schema}, stacks) do
    fits!(stacks)
    to_tag(schema, stacks)
  end

  def to_tag(_schema, _value), do: fail(:invalid_value)

  # `optionalFieldOf` omits an absent value and one equal to its default.
  defp omitted?({_, {:optional, _}}, nil), do: true
  defp omitted?({_, _, {:present, _}}, _), do: false
  defp omitted?({_, _, default}, value), do: value === default
  defp omitted?(_, _), do: false

  defp filterable(schema), do: {:record, [{"raw", schema}, {"filtered", {:optional, schema}}]}

  # `StringUtil.isValidPlayerName`.
  defp player_name?(value),
    do: valid_string?(value, 16) and Enum.all?(String.to_charlist(value), &(&1 > 32 and &1 < 127))

  defp take_compound(bytes) do
    case NBT.take(bytes) do
      {:ok, {:compound, _} = tag, rest} -> {tag, rest}
      {:ok, _, _} -> fail(:not_a_compound)
      {:error, reason} -> fail({:nbt, reason})
    end
  end

  defp strip_id({:compound, values}), do: {:compound, Map.delete(values, "id")}

  ## Templates

  # Templates hold templates (a shulker box in a bundle in a shulker box ...).
  defp nested(fun) do
    depth = Process.get(@nesting, 0)
    check(depth < @max_nesting, :nesting_too_deep)
    Process.put(@nesting, depth + 1)

    try do
      fun.()
    after
      if depth == 0, do: Process.delete(@nesting), else: Process.put(@nesting, depth)
    end
  end

  defp fits!(stacks) when is_list(stacks) do
    for %ItemStack{} = stack <- stacks,
        do: check(stack.count <= ItemStack.max_stack_size(stack), :stack_size_exceeded)

    :ok
  end

  defp fits!(_), do: fail(:invalid_value)

  ## Records

  defp field_name({name, _}), do: name
  defp field_name({name, _, _}), do: name
  defp field_schema({_, schema}), do: schema
  defp field_schema({_, schema, _}), do: schema

  ## Registries

  @doc "The entry of `registry` at network id `id`, or nil."
  def registry_name("minecraft:item", id), do: ItemTypes.item(id) && ItemTypes.item(id)["name"]

  def registry_name("minecraft:block", id) when is_integer(id) and id >= 0,
    do: if(id < Valimc.Data.Blocks.block_count(), do: "minecraft:" <> Valimc.Data.Blocks.name(id))

  def registry_name("minecraft:entity_type", id) do
    Valimc.Data.EntityTypes.name(id)
  rescue
    _ -> nil
  end

  def registry_name("minecraft:mob_effect", id) when is_integer(id) and id >= 0,
    do: if(id < Valimc.Data.EffectTypes.count(), do: Valimc.Data.EffectTypes.name(id))

  def registry_name(registry, id) when is_integer(id) and id >= 0 do
    if BuiltinRegistries.registry?(registry) do
      BuiltinRegistries.name(registry, id)
    else
      entries = Map.get(Valimc.Protocol.Data.registries(), registry, [])
      if id < length(entries), do: Valimc.Protocol.Data.registry_name(registry, id)
    end
  end

  def registry_name(_, _), do: nil

  @doc "The network id of an entry of `registry`, or nil."
  def registry_id(_registry, value) when not is_binary(value), do: nil

  def registry_id("minecraft:item", value),
    do: if(ItemTypes.known?(value), do: ItemTypes.id(value))

  def registry_id("minecraft:block", "minecraft:" <> name), do: Valimc.Data.Blocks.id(name)
  def registry_id("minecraft:block", _), do: nil

  def registry_id("minecraft:entity_type", value) do
    Valimc.Data.EntityTypes.id(value)
  rescue
    _ -> nil
  end

  def registry_id("minecraft:mob_effect", value) do
    Valimc.Data.EffectTypes.id(value)
  rescue
    _ -> nil
  end

  def registry_id(registry, value) do
    if BuiltinRegistries.registry?(registry),
      do: BuiltinRegistries.id(registry, value),
      else: Valimc.Protocol.Data.find_registry_id(registry, value)
  end

  defp tag?(registry, tag), do: Valimc.Protocol.Registries.tag(registry, tag) != nil

  defp enum_id(name, value) do
    Enum.find_value(ComponentTypes.enum(name), fn {id, entry} -> if entry == value, do: id end)
  end

  ## Primitives

  defp signed32(value) when value >= 0x80000000, do: value - 0x100000000
  defp signed32(value), do: value

  defp float32(bits) when (bits &&& 0x7F800000) == 0x7F800000, do: {:float_bits, bits}

  defp float32(bits) do
    <<value::float-32>> = <<bits::32>>
    value
  end

  defp float64(bits) when (bits &&& 0x7FF0000000000000) == 0x7FF0000000000000,
    do: {:double_bits, bits}

  defp float64(bits) do
    <<value::float-64>> = <<bits::64>>
    value
  end

  defp float32_bits({:float_bits, bits}), do: bits

  defp float32_bits(value) when is_float(value) do
    <<bits::32>> = <<value::float-32>>
    bits
  end

  defp float32_bits(_), do: fail(:invalid_value)
  defp float64_bits({:double_bits, bits}), do: bits

  defp float64_bits(value) when is_float(value) do
    <<bits::64>> = <<value::float-64>>
    bits
  end

  defp float64_bits(_), do: fail(:invalid_value)

  defp in_range?(value, min, max) when is_number(value),
    do: above?(value, min) and (max == nil or value <= max)

  defp in_range?(_, _, _), do: false
  defp above?(_, nil), do: true
  defp above?(value, {:gt, min}), do: value > min
  defp above?(value, min), do: value >= min

  defp take_string(bytes, max) do
    {size, rest} = take(:varint, bytes)
    check(size >= 0 and size <= max * 3 and size <= byte_size(rest), :invalid_string)
    <<value::binary-size(^size), tail::binary>> = rest
    check(valid_string?(value, max), :invalid_string)
    {value, tail}
  end

  # Java counts a string's length in UTF-16 units.
  defp valid_string?(value, max) when is_binary(value) do
    String.valid?(value) and utf16_length(value, 0, max) <= max
  end

  defp valid_string?(_, _), do: false

  defp utf16_length(_, count, max) when count > max, do: count
  defp utf16_length(<<>>, count, _), do: count

  defp utf16_length(<<c::utf8, rest::binary>>, count, max),
    do: utf16_length(rest, count + if(c > 0xFFFF, do: 2, else: 1), max)

  defp identifier({value, rest}) do
    value =
      case String.split(value, ":", parts: 2) do
        [path] -> "minecraft:" <> path
        ["", path] -> "minecraft:" <> path
        _ -> value
      end

    check(identifier?(value), :invalid_identifier)
    {value, rest}
  end

  defp identifier?(value),
    do: is_binary(value) and Regex.match?(~r/\A[a-z0-9_.-]+:[a-z0-9_\/.\-]*\z/, value)

  # `NbtOps.getNumberValue`: any numeric tag, converted as Java's `Number` does.
  defp number({type, value}) when type in [:byte, :short, :int, :long], do: value
  defp number({:float, <<value::float-32>>}), do: value
  defp number({:double, <<value::float-64>>}), do: value
  defp number(_), do: fail(:not_a_number)

  defp int({:long, value}), do: signed32(value &&& 0xFFFFFFFF)
  defp int({type, _} = tag) when type in [:float, :double], do: saturate(number(tag), 32)
  defp int(tag), do: number(tag)

  defp long({type, _} = tag) when type in [:float, :double], do: saturate(number(tag), 64)
  defp long(tag), do: number(tag)

  defp saturate(value, bits) do
    limit = 1 <<< (bits - 1)
    value |> trunc() |> max(-limit) |> min(limit - 1)
  end

  defp channel(value), do: value |> Kernel.*(255.0) |> trunc() |> max(0) |> min(255)

  defp items({:list, _} = list), do: NBT.items(list)

  defp items({:byte_array, bytes}), do: for(<<v::signed-8 <- bytes>>, do: {:byte, v})
  defp items({:int_array, bytes}), do: for(<<v::signed-32 <- bytes>>, do: {:int, v})
  defp items({:long_array, bytes}), do: for(<<v::signed-64 <- bytes>>, do: {:long, v})
  defp items(_), do: fail(:not_a_list)

  defp check(true, _), do: :ok
  defp check(false, reason), do: fail(reason)
  defp fail(reason), do: throw({:component_error, reason})
end
