defmodule Valimc.Protocol.NBT do
  @moduledoc "Bounded unnamed network NBT. Dense arrays and floating-point bits stay binary."
  import Bitwise

  @types %{
    0 => :end,
    1 => :byte,
    2 => :short,
    3 => :int,
    4 => :long,
    5 => :float,
    6 => :double,
    7 => :byte_array,
    8 => :string,
    9 => :list,
    10 => :compound,
    11 => :int_array,
    12 => :long_array
  }
  @ids Map.new(@types, fn {id, type} -> {type, id} end)
  @integers %{byte: 1, short: 2, int: 4, long: 8}
  @floats %{float: 4, double: 8}
  @arrays %{byte_array: 1, int_array: 4, long_array: 8}
  @budget {65_536, 1024}
  @four_byte_prefixes [<<0xF0>>, <<0xF1>>, <<0xF2>>, <<0xF3>>, <<0xF4>>]

  def take(bytes) do
    {<<id>>, bytes, budget} = cut(bytes, 1, @budget)
    type = type!(id)
    {value, rest, _} = read(type, bytes, budget, 0)
    {:ok, {type, value}, rest}
  rescue
    ArgumentError -> {:error, :malformed_nbt}
    MatchError -> {:error, :malformed_nbt}
    FunctionClauseError -> {:error, :malformed_nbt}
  catch
    {:nbt_error, reason} -> {:error, reason}
  end

  def decode(bytes) do
    case take(bytes) do
      {:ok, tag, <<>>} -> {:ok, tag}
      {:ok, _, _} -> {:error, :trailing_nbt_bytes}
      error -> error
    end
  end

  def encode({type, value}) do
    id = @ids[type]
    check(id != nil, :unknown_nbt_tag)
    {prefix, budget} = emit(<<id>>, @budget)
    {payload, _} = write(type, value, budget, 0)
    [prefix, payload]
  end

  def valid?(tag) do
    encode(tag)
    true
  rescue
    _ -> false
  catch
    {:nbt_error, _} -> false
  end

  def float(value), do: {:float, <<value::float-32>>}
  def double(value), do: {:double, <<value::float-64>>}

  @doc "Typed NBT comparison bytes: Mojang NaN equality, cached numeric zero and empty-list equality."
  def identity_key({type, value} = tag) do
    # Enforce the byte/node/depth budget before recursively visiting an input tree.
    encode(tag)
    encode({type, identity_value(type, value)}) |> IO.iodata_to_binary()
  end

  defp identity_value(:float, <<_sign::1, 255::8, mantissa::23>>) when mantissa != 0,
    do: <<0x7FC00000::32>>

  defp identity_value(:double, <<_sign::1, 2047::11, mantissa::52>>) when mantissa != 0,
    do: <<0x7FF8000000000000::64>>

  defp identity_value(:float, <<_sign::1, 0::31>>), do: <<0::32>>
  defp identity_value(:double, <<_sign::1, 0::63>>), do: <<0::64>>

  defp identity_value(:compound, values),
    do:
      Map.new(values, fn {name, {type, value}} -> {name, {type, identity_value(type, value)}} end)

  defp identity_value(:list, {_type, []}), do: {:end, []}

  defp identity_value(:list, {type, values}),
    do: {type, Enum.map(values, &identity_value(type, &1))}

  defp identity_value(_, value), do: value

  defp read(type, bytes, budget, depth) do
    budget = node(budget, depth)

    cond do
      type == :end ->
        {nil, bytes, budget}

      size = @integers[type] ->
        {raw, bytes, budget} = cut(bytes, size, budget)
        bits = size * 8
        <<value::signed-size(^bits)>> = raw
        {value, bytes, budget}

      size = @floats[type] ->
        {raw, bytes, budget} = cut(bytes, size, budget)
        {retain(raw), bytes, budget}

      width = @arrays[type] ->
        {<<count::signed-32>>, bytes, budget} = cut(bytes, 4, budget)
        check(count >= 0, :invalid_nbt_array_length)
        {raw, bytes, budget} = cut(bytes, count * width, budget)
        {retain(raw), bytes, budget}

      type == :string ->
        read_string(bytes, budget)

      type == :list ->
        {<<id, count::signed-32>>, bytes, budget} = cut(bytes, 5, budget)
        subtype = type!(id)
        check(count >= 0 and count <= elem(budget, 1), :nbt_node_limit)
        check(subtype != :end or count == 0, :invalid_nbt_list)
        {values, bytes, budget} = read_list(subtype, count, bytes, budget, depth + 1, [])
        {{subtype, values}, bytes, budget}

      type == :compound ->
        read_compound(bytes, budget, depth + 1, %{})
    end
  end

  defp read_list(_, 0, bytes, budget, _, values), do: {Enum.reverse(values), bytes, budget}

  defp read_list(type, count, bytes, budget, depth, values) do
    {value, bytes, budget} = read(type, bytes, budget, depth)
    read_list(type, count - 1, bytes, budget, depth, [value | values])
  end

  defp read_compound(bytes, budget, depth, values) do
    {<<id>>, bytes, budget} = cut(bytes, 1, budget)

    if id == 0 do
      {values, bytes, budget}
    else
      type = type!(id)
      {name, bytes, budget} = read_string(bytes, budget)
      check(not Map.has_key?(values, name), :duplicate_nbt_name)
      {value, bytes, budget} = read(type, bytes, budget, depth)
      read_compound(bytes, budget, depth, Map.put(values, name, {type, value}))
    end
  end

  defp read_string(bytes, budget) do
    {<<size::16>>, bytes, budget} = cut(bytes, 2, budget)
    {raw, bytes, budget} = cut(bytes, size, budget)

    value =
      if String.valid?(raw) and :binary.match(raw, @four_byte_prefixes) == :nomatch,
        do: retain(raw),
        else: decode_modified(raw)

    {value, bytes, budget}
  end

  defp write(type, value, budget, depth) do
    budget = node(budget, depth)

    cond do
      type == :end ->
        check(value == nil, :invalid_nbt_value)
        {[], budget}

      size = @integers[type] ->
        bits = size * 8

        check(
          is_integer(value) and value >= -(1 <<< (bits - 1)) and value < 1 <<< (bits - 1),
          :invalid_nbt_value
        )

        emit(<<value::signed-size(bits)>>, budget)

      size = @floats[type] ->
        check(is_binary(value) and byte_size(value) == size, :invalid_nbt_value)
        emit(value, budget)

      width = @arrays[type] ->
        check(is_binary(value) and rem(byte_size(value), width) == 0, :invalid_nbt_value)
        emit([<<div(byte_size(value), width)::signed-32>>, value], budget)

      type == :string ->
        write_string(value, budget)

      type == :list ->
        {subtype, values} = value
        id = @ids[subtype]
        check(id != nil and is_list(values), :invalid_nbt_list)
        check(length(values) <= elem(budget, 1), :nbt_node_limit)
        check(subtype != :end or values == [], :invalid_nbt_list)
        {prefix, budget} = emit(<<id, length(values)::signed-32>>, budget)
        {parts, budget} = Enum.map_reduce(values, budget, &write(subtype, &1, &2, depth + 1))
        {[prefix, parts], budget}

      type == :compound ->
        check(is_map(value) and map_size(value) <= elem(budget, 1), :nbt_node_limit)

        {parts, budget} =
          Enum.map_reduce(Enum.sort(value), budget, fn {name, {subtype, data}}, budget ->
            id = @ids[subtype]
            check(id != nil and id != 0, :invalid_nbt_value)
            {id, budget} = emit(<<id>>, budget)
            {name, budget} = write_string(name, budget)
            {data, budget} = write(subtype, data, budget, depth + 1)
            {[id, name, data], budget}
          end)

        {ending, budget} = emit(<<0>>, budget)
        {[parts, ending], budget}

      true ->
        throw({:nbt_error, :unknown_nbt_tag})
    end
  end

  defp write_string(value, budget) do
    check(
      is_binary(value) and byte_size(value) <= 65_535 and String.valid?(value),
      :invalid_nbt_utf
    )

    raw =
      if :binary.match(value, [<<0>>, <<0xF0>>, <<0xF1>>, <<0xF2>>, <<0xF3>>, <<0xF4>>]) ==
           :nomatch, do: value, else: encode_modified(value)

    check(byte_size(raw) <= 65_535, :invalid_nbt_string_length)
    emit([<<byte_size(raw)::16>>, raw], budget)
  end

  defp encode_modified(value) do
    utf16 = :unicode.characters_to_binary(value, :utf8, {:utf16, :big})

    for <<unit::16 <- utf16>>, into: <<>> do
      cond do
        unit in 1..127 -> <<unit>>
        unit <= 2047 -> <<0xC0 ||| unit >>> 6, 0x80 ||| (unit &&& 63)>>
        true -> <<0xE0 ||| unit >>> 12, 0x80 ||| (unit >>> 6 &&& 63), 0x80 ||| (unit &&& 63)>>
      end
    end
  end

  defp decode_modified(bytes) do
    utf16 = bytes |> units([]) |> Enum.reverse() |> IO.iodata_to_binary()
    value = :unicode.characters_to_binary(utf16, {:utf16, :big}, :utf8)
    check(is_binary(value), :invalid_nbt_utf)
    value
  end

  defp units(<<>>, units), do: units

  defp units(<<byte, rest::binary>>, units) when byte < 128,
    do: units(rest, [<<byte::16>> | units])

  defp units(<<first, second, rest::binary>>, units)
       when first in 0xC0..0xDF and (second &&& 0xC0) == 0x80,
       do: units(rest, [<<(first &&& 31) <<< 6 ||| (second &&& 63)::16>> | units])

  defp units(<<first, second, third, rest::binary>>, units)
       when first in 0xE0..0xEF and (second &&& 0xC0) == 0x80 and (third &&& 0xC0) == 0x80,
       do:
         units(rest, [
           <<(first &&& 15) <<< 12 ||| (second &&& 63) <<< 6 ||| (third &&& 63)::16>> | units
         ])

  defp units(_, _), do: throw({:nbt_error, :invalid_nbt_utf})

  defp cut(bytes, size, {left, nodes}) do
    check(size <= left, :nbt_byte_limit)
    check(size <= byte_size(bytes), :truncated_nbt)
    <<value::binary-size(^size), rest::binary>> = bytes
    {value, rest, {left - size, nodes}}
  end

  defp emit(data, {left, nodes}) do
    size = IO.iodata_length(data)
    check(size <= left, :nbt_byte_limit)
    {data, {left - size, nodes}}
  end

  defp node({bytes, nodes}, depth) do
    check(depth <= 32, :nbt_depth_limit)
    check(nodes > 0, :nbt_node_limit)
    {bytes, nodes - 1}
  end

  defp retain(bytes),
    do: if(:binary.referenced_byte_size(bytes) > 65_536, do: :binary.copy(bytes), else: bytes)

  defp type!(id), do: @types[id] || throw({:nbt_error, :unknown_nbt_tag})
  defp check(true, _), do: :ok
  defp check(false, reason), do: throw({:nbt_error, reason})
end
