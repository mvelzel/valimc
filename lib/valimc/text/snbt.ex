defmodule Valimc.Text.Snbt do
  @moduledoc """
  Vanilla 26.3 SNBT (`SnbtGrammar`, `TagParser`) as `Valimc.Data.NBT` tags, for
  command arguments (VMC-053g): numbers with sign, base and type suffixes,
  quoted and unquoted strings with escapes, lists, typed arrays, compounds and
  the `bool(...)`/`uuid(...)` built-ins, with vanilla's errors.

  `\\N{name}` escapes need Java's Unicode character-name table and are refused
  with a ValiMC message, as are escapes that produce lone surrogates.
  """
  alias Valimc.Data.Float32
  alias Valimc.Text.{Error, Packrat, Reader}
  import Packrat, only: [get: 2, get: 3, get_any: 2, mark: 1, store: 3]

  @int_min -2_147_483_648
  @int_max 2_147_483_647

  @doc "`TagParser.parseAsArgument`: any tag; the reader stops after it."
  def parse(reader), do: Packrat.parse(rules(), :literal, reader) |> unwrap()

  @doc "`TagParser.parseCompoundAsArgument`: a compound, else `argument.nbt.expected.compound`."
  def parse_compound(reader) do
    case parse(reader) do
      {{:compound, _} = tag, reader} -> {tag, reader}
      {_tag, reader} -> Error.fail_at!("argument.nbt.expected.compound", [], reader)
    end
  end

  defp unwrap({:ok, value, reader}), do: {value, reader}

  defp delayed(key, args \\ []), do: {:delayed, "snbt.parser." <> key, args}

  defp number_start?(c), do: c in [?+, ?-, ?.] or c in ?0..?9

  # ---- grammar ----

  defp rules do
    case :persistent_term.get({__MODULE__, :rules}, nil) do
      nil ->
        rules = build()
        :persistent_term.put({__MODULE__, :rules}, rules)
        rules

      rules ->
        rules
    end
  end

  defp chars(list), do: {:chars, String.to_charlist(list)}
  defp ref(name), do: {:ref, name, name}
  defp ref(name, as), do: {:ref, name, as}
  defp seq(terms), do: {:seq, terms}
  defp alt(terms), do: {:alt, terms}
  defp opt(term), do: {:opt, term}
  defp marker(atom, value), do: {:marker, atom, value}
  defp look(term), do: {:look, term, true}
  defp self(atom), do: fn state -> {get(state, atom), state} end

  defp suffix(chars, signed, type),
    do: seq([chars(chars), marker(:integer_suffix, {signed, type})])

  defp typed(signed) do
    alt([
      suffix("bB", signed, :byte),
      suffix("sS", signed, :short),
      suffix("iI", signed, :int),
      suffix("lL", signed, :long)
    ])
  end

  defp build do
    %{
      sign:
        {:term,
         alt([seq([chars("+"), marker(:sign, :plus)]), seq([chars("-"), marker(:sign, :minus)])]),
         self(:sign)},
      integer_suffix:
        {:term,
         alt([
           seq([chars("uU"), typed(:unsigned)]),
           seq([chars("sS"), typed(:signed)]),
           suffix("bB", nil, :byte),
           suffix("sS", nil, :short),
           suffix("iI", nil, :int),
           suffix("lL", nil, :long)
         ]), self(:integer_suffix)},
      binary_numeral: {:prim, number_run(&(&1 in [?0, ?1, ?_]), "expected_binary_numeral")},
      decimal_numeral:
        {:prim, number_run(&(&1 in ?0..?9 or &1 == ?_), "expected_decimal_numeral")},
      hex_numeral:
        {:prim,
         number_run(
           &(&1 in ?0..?9 or &1 in ?A..?F or &1 in ?a..?f or &1 == ?_),
           "expected_hex_numeral"
         )},
      integer_literal:
        {:term,
         seq([
           opt(ref(:sign)),
           alt([
             seq([
               chars("0"),
               :cut,
               alt([
                 seq([chars("xX"), :cut, ref(:hex_numeral)]),
                 seq([chars("bB"), ref(:binary_numeral)]),
                 seq([ref(:decimal_numeral), :cut, {:fail, delayed("leading_zero_not_allowed")}]),
                 marker(:decimal_numeral, "0")
               ])
             ]),
             ref(:decimal_numeral)
           ]),
           opt(ref(:integer_suffix))
         ]), &integer_literal/1},
      float_type_suffix:
        {:term,
         alt([
           seq([chars("fF"), marker(:float_type_suffix, :float)]),
           seq([chars("dD"), marker(:float_type_suffix, :double)])
         ]), self(:float_type_suffix)},
      float_exponent_part:
        {:term, seq([chars("eE"), opt(ref(:sign)), ref(:decimal_numeral)]),
         fn state -> {{get(state, :sign, :plus), get(state, :decimal_numeral)}, state} end},
      float_literal:
        {:term,
         seq([
           opt(ref(:sign)),
           alt([
             seq([
               ref(:decimal_numeral, :float_whole_part),
               chars("."),
               :cut,
               opt(ref(:decimal_numeral, :float_fraction_part)),
               opt(ref(:float_exponent_part)),
               opt(ref(:float_type_suffix))
             ]),
             seq([
               chars("."),
               :cut,
               ref(:decimal_numeral, :float_fraction_part),
               opt(ref(:float_exponent_part)),
               opt(ref(:float_type_suffix))
             ]),
             seq([
               ref(:decimal_numeral, :float_whole_part),
               ref(:float_exponent_part),
               :cut,
               opt(ref(:float_type_suffix))
             ]),
             seq([
               ref(:decimal_numeral, :float_whole_part),
               opt(ref(:float_exponent_part)),
               ref(:float_type_suffix)
             ])
           ])
         ]), &float_literal/1},
      string_hex_2: {:prim, hex_escape(2)},
      string_hex_4: {:prim, hex_escape(4)},
      string_hex_8: {:prim, hex_escape(8)},
      string_unicode_name: {:prim, &unicode_name/1},
      string_escape_sequence:
        {:term,
         alt(
           for(
             {c, value} <- [
               {"b", "\b"},
               {"s", " "},
               {"t", "\t"},
               {"n", "\n"},
               {"f", "\f"},
               {"r", "\r"},
               {"\\", "\\"},
               {"'", "'"},
               {"\"", "\""}
             ],
             do: seq([chars(c), marker(:string_escape_sequence, value)])
           ) ++
             [
               seq([chars("x"), ref(:string_hex_2)]),
               seq([chars("u"), ref(:string_hex_4)]),
               seq([chars("U"), ref(:string_hex_8)]),
               seq([chars("N"), chars("{"), ref(:string_unicode_name), chars("}")])
             ]
         ), &escape/1},
      string_plain_contents: {:prim, &plain_chunk/1},
      single_quoted_string_chunk:
        {:term,
         alt([
           ref(:string_plain_contents, :string_contents),
           seq([chars("\\"), ref(:string_escape_sequence, :string_contents)]),
           seq([chars("\""), marker(:string_contents, "\"")])
         ]), self(:string_contents)},
      single_quoted_string_contents:
        {:term, {:rep, :single_quoted_string_chunk, :string_chunks}, &join_chunks/1},
      double_quoted_string_chunk:
        {:term,
         alt([
           ref(:string_plain_contents, :string_contents),
           seq([chars("\\"), ref(:string_escape_sequence, :string_contents)]),
           seq([chars("'"), marker(:string_contents, "'")])
         ]), self(:string_contents)},
      double_quoted_string_contents:
        {:term, {:rep, :double_quoted_string_chunk, :string_chunks}, &join_chunks/1},
      quoted_string_literal:
        {:term,
         alt([
           seq([
             chars("\""),
             :cut,
             opt(ref(:double_quoted_string_contents, :string_contents)),
             chars("\"")
           ]),
           seq([
             chars("'"),
             opt(ref(:single_quoted_string_contents, :string_contents)),
             chars("'")
           ])
         ]), self(:string_contents)},
      unquoted_string: {:prim, &unquoted_string/1},
      arguments: {:term, {:rep_sep, :literal, :arguments, chars(",")}, self(:arguments)},
      unquoted_string_or_builtin:
        {:term, seq([ref(:unquoted_string), opt(seq([chars("("), ref(:arguments), chars(")")]))]),
         &builtin/1},
      map_key:
        {:term, alt([ref(:quoted_string_literal), ref(:unquoted_string)]),
         fn state -> {get_any(state, [:quoted_string_literal, :unquoted_string]), state} end},
      map_entry: {:term, seq([ref(:map_key), chars(":"), ref(:literal)]), &map_entry/1},
      map_entries: {:term, {:rep_sep, :map_entry, :map_entries, chars(",")}, self(:map_entries)},
      map_literal: {:term, seq([chars("{"), ref(:map_entries), chars("}")]), &map_literal/1},
      list_entries: {:term, {:rep_sep, :literal, :list_entries, chars(",")}, self(:list_entries)},
      array_prefix:
        {:term,
         alt([
           seq([chars("B"), marker(:array_prefix, :byte)]),
           seq([chars("L"), marker(:array_prefix, :long)]),
           seq([chars("I"), marker(:array_prefix, :int)])
         ]), self(:array_prefix)},
      int_array_entries:
        {:term, {:rep_sep, :integer_literal, :int_array_entries, chars(",")},
         self(:int_array_entries)},
      list_literal:
        {:term,
         seq([
           chars("["),
           alt([
             seq([ref(:array_prefix), chars(";"), ref(:int_array_entries)]),
             ref(:list_entries)
           ]),
           chars("]")
         ]), &list_literal/1},
      literal:
        {:term,
         alt([
           seq([
             look({:chars, &number_start?/1}),
             alt([ref(:float_literal, :literal), ref(:integer_literal)])
           ]),
           seq([look(chars("\"'")), :cut, ref(:quoted_string_literal)]),
           seq([look(chars("{")), :cut, ref(:map_literal, :literal)]),
           seq([look(chars("[")), :cut, ref(:list_literal, :literal)]),
           ref(:unquoted_string_or_builtin, :literal)
         ]), &literal/1}
    }
  end

  # ---- primitives ----

  defp number_run(accepted, error) do
    fn state ->
      reader = Reader.skip_whitespace(state.reader)
      state = %{state | reader: reader}
      start = reader.cursor
      {text, after_run} = Reader.take_while(reader, accepted)

      cond do
        text == "" ->
          {nil, store(state, start, delayed(error))}

        String.starts_with?(text, "_") or String.ends_with?(text, "_") ->
          {nil, store(state, start, delayed("underscore_not_allowed"))}

        true ->
          {text, %{state | reader: after_run}}
      end
    end
  end

  defp hex_escape(size) do
    fn state ->
      reader = state.reader
      hex? = &(&1 in ?0..?9 or &1 in ?A..?F or &1 in ?a..?f)
      stop = scan(reader, reader.cursor, hex?, size)

      if stop - reader.cursor < size,
        do:
          {nil,
           store(state, reader.cursor, delayed("expected_hex_escape", [Integer.to_string(size)]))},
        else:
          {Reader.slice(reader, reader.cursor, stop),
           %{state | reader: Reader.set_cursor(reader, stop)}}
    end
  end

  defp scan(reader, i, accepted, max) do
    if i < reader.size and i - reader.cursor < max and accepted.(elem(reader.units, i)),
      do: scan(reader, i + 1, accepted, max),
      else: i
  end

  defp unicode_name(state) do
    name? = &(&1 == ?- or &1 == ?\s or &1 in ?a..?z or &1 in ?A..?Z or &1 in ?0..?9)
    {text, after_name} = Reader.take_while(state.reader, name?)

    if text == "",
      do: {nil, store(state, mark(state), delayed("invalid_character_name"))},
      else: {text, %{state | reader: after_name}}
  end

  defp plain_chunk(state) do
    {text, after_chunk} = Reader.take_while(state.reader, &(&1 not in [?", ?', ?\\]))

    if text == "",
      do: {nil, store(state, mark(state), delayed("invalid_string_contents"))},
      else: {text, %{state | reader: after_chunk}}
  end

  defp unquoted_string(state) do
    reader = Reader.skip_whitespace(state.reader)
    cursor = reader.cursor
    {text, reader} = Reader.read_unquoted_string(reader)
    state = %{state | reader: reader}

    if text == "",
      do: {nil, store(state, cursor, delayed("expected_unquoted_string"))},
      else: {text, state}
  end

  # ---- actions ----

  defp join_chunks(state), do: {Enum.join(get(state, :string_chunks)), state}

  defp escape(state) do
    cond do
      (plain = get_any(state, [:string_escape_sequence])) != nil ->
        {plain, state}

      (hex = get_any(state, [:string_hex_2, :string_hex_4, :string_hex_8])) != nil ->
        code = String.to_integer(hex, 16)

        cond do
          code > 0x10FFFF ->
            label = "U+" <> String.pad_leading(String.upcase(Integer.to_string(code, 16)), 8, "0")
            {nil, store(state, mark(state), delayed("invalid_codepoint", [label]))}

          code in 0xD800..0xDFFF ->
            unsupported(state, "Surrogate escapes in SNBT are not supported yet")

          true ->
            {<<code::utf8>>, state}
        end

      true ->
        unsupported(state, "Unicode name escapes in SNBT are not supported yet")
    end
  end

  defp unsupported(state, text),
    do: {nil, store(state, mark(state), Error.unsupported(text, state.reader))}

  defp integer_literal(state) do
    suffix = get(state, :integer_suffix, {nil, nil}) || {nil, nil}
    sign = get(state, :sign, :plus) || :plus

    literal =
      cond do
        (digits = get(state, :decimal_numeral)) != nil -> {sign, :decimal, digits, suffix}
        (digits = get(state, :hex_numeral)) != nil -> {sign, :hex, digits, suffix}
        true -> {sign, :binary, get(state, :binary_numeral), suffix}
      end

    {literal, state}
  end

  # `IntegerLiteral.create`: a typed tag, or nil with vanilla's error stored.
  defp create_integer({sign, base, digits, {signed, _}}, type, state) do
    signed = signed || if(base == :decimal, do: :signed, else: :unsigned)

    if signed == :unsigned and sign == :minus do
      {nil, store(state, mark(state), delayed("expected_non_negative_number"))}
    else
      clean = if(sign == :minus, do: "-", else: "") <> String.replace(digits, "_", "")
      radix = %{binary: 2, decimal: 10, hex: 16}[base]

      case java_integer(clean, radix, type, signed) do
        {:ok, value} ->
          {{type, value}, state}

        {:error, message} ->
          {nil, store(state, mark(state), delayed("number_parse_failure", [message]))}
      end
    end
  end

  defp float_literal(state) do
    sign = get(state, :sign, :plus) || :plus
    whole = get(state, :float_whole_part)
    fraction = get(state, :float_fraction_part)
    exponent = get(state, :float_exponent_part)
    type = get(state, :float_type_suffix)
    whole_digits = String.replace(whole || "", "_", "")
    fraction_digits = String.replace(fraction || "", "_", "")

    exponent_text =
      case exponent do
        nil ->
          "0"

        {exp_sign, digits} ->
          if(exp_sign == :minus, do: "-", else: "") <> String.replace(digits, "_", "")
      end

    text =
      "#{if whole_digits == "", do: "0", else: whole_digits}.#{if fraction_digits == "", do: "0", else: fraction_digits}e#{exponent_text}"

    value =
      try do
        String.to_float(text)
      rescue
        ArgumentError -> :infinity
      end

    value = if value != :infinity and sign == :minus, do: -value, else: value

    case {type, value} do
      {_, :infinity} ->
        {nil, store(state, mark(state), delayed("infinity_not_allowed"))}

      {:float, value} ->
        case Float32.round_or_infinity(value) do
          f when f in [:infinity, :neg_infinity] ->
            {nil, store(state, mark(state), delayed("infinity_not_allowed"))}

          f ->
            {{:float, <<f::float-32>>}, state}
        end

      {_double, value} ->
        {{:double, <<value::float-64>>}, state}
    end
  end

  defp builtin(state) do
    contents = get(state, :unquoted_string)
    first = :binary.first(contents)

    cond do
      number_start?(first) ->
        {nil, store(state, mark(state), delayed("invalid_unquoted_start"))}

      (arguments = get(state, :arguments)) != nil ->
        operation(contents, arguments, state)

      String.downcase(contents) == "true" ->
        {{:byte, 1}, state}

      String.downcase(contents) == "false" ->
        {{:byte, 0}, state}

      true ->
        {{:string, contents}, state}
    end
  end

  defp operation("bool", [argument], state) do
    case argument do
      {type, value} when type in [:byte, :short, :int, :long] ->
        {{:byte, if(Bitwise.band(value, 0xFF) != 0, do: 1, else: 0)}, state}

      {:float, <<value::float-32>>} ->
        {{:byte, if(byte_value(value) != 0, do: 1, else: 0)}, state}

      {:double, <<value::float-64>>} ->
        {{:byte, if(byte_value(value) != 0, do: 1, else: 0)}, state}

      _ ->
        {nil, store(state, mark(state), delayed("expected_number_or_boolean"))}
    end
  end

  defp operation("uuid", [{:string, text}], state) do
    case Valimc.Data.UUID.parse(text) do
      {:ok, uuid} -> {{:int_array, uuid}, state}
      :error -> {nil, store(state, mark(state), delayed("expected_string_uuid"))}
    end
  end

  defp operation("uuid", [_], state),
    do: {nil, store(state, mark(state), delayed("expected_string_uuid"))}

  defp operation(id, arguments, state),
    do:
      {nil,
       store(state, mark(state), delayed("no_such_operation", ["#{id}/#{length(arguments)}"]))}

  # Java `Number.byteValue()` of a floating value: truncate to long, keep the low byte.
  defp byte_value(value), do: Bitwise.band(trunc(value), 0xFF)

  defp map_entry(state) do
    case get(state, :map_key) do
      "" -> {nil, store(state, mark(state), delayed("empty_key"))}
      key -> {{key, get(state, :literal)}, state}
    end
  end

  defp map_literal(state), do: {{:compound, Map.new(get(state, :map_entries))}, state}

  defp list_literal(state) do
    case get(state, :array_prefix) do
      nil ->
        {Valimc.Data.NBT.list(get(state, :list_entries)), state}

      prefix ->
        entries = get(state, :int_array_entries)

        {default, allowed, tag} =
          %{
            byte: {:byte, [:byte], :byte_array},
            int: {:int, [:int, :byte, :short], :int_array},
            long: {:long, [:long, :byte, :short, :int], :long_array}
          }[prefix]

        Enum.reduce_while(entries, {[], state}, fn {_, _, _, {_, type}} = entry, {acc, state} ->
          type = type || default

          if type in allowed do
            case create_integer(entry, type, state) do
              {nil, state} -> {:halt, {nil, state}}
              {{_, value}, state} -> {:cont, {[value | acc], state}}
            end
          else
            {:halt, {nil, store(state, mark(state), delayed("invalid_array_element_type"))}}
          end
        end)
        |> case do
          {nil, state} -> {nil, state}
          {values, state} -> {{tag, pack(prefix, Enum.reverse(values))}, state}
        end
    end
  end

  defp pack(:byte, values), do: for(v <- values, into: <<>>, do: <<v::signed-8>>)
  defp pack(:int, values), do: for(v <- values, into: <<>>, do: <<v::signed-32>>)
  defp pack(:long, values), do: for(v <- values, into: <<>>, do: <<v::signed-64>>)

  defp literal(state) do
    cond do
      (quoted = get(state, :quoted_string_literal)) != nil ->
        {{:string, quoted}, state}

      (integer = get(state, :integer_literal)) != nil ->
        {_, _, _, {_, type}} = integer
        create_integer(integer, type || :int, state)

      true ->
        {get(state, :literal), state}
    end
  end

  # ---- Java number parsing with its exception messages ----

  defp java_integer(text, radix, type, :signed) do
    case type do
      :byte -> small(text, radix, -128..127)
      :short -> small(text, radix, -32_768..32_767)
      :int -> java_parse(text, radix, @int_min..@int_max)
      :long -> java_parse(text, radix, -0x8000000000000000..0x7FFFFFFFFFFFFFFF)
    end
  end

  defp java_integer(text, radix, type, :unsigned) do
    case type do
      :byte -> unsigned_small(text, radix, 8)
      :short -> unsigned_small(text, radix, 16)
      :int -> unsigned_int(text, radix)
      :long -> unsigned_long(text, radix)
    end
  end

  # `Byte/Short.parseByte`: `Integer.parseInt`, then the range message.
  defp small(text, radix, range) do
    with {:ok, value} <- java_parse(text, radix, @int_min..@int_max) do
      if value in range,
        do: {:ok, value},
        else: {:error, ~s(Value out of range. Value:"#{text}" Radix:#{radix})}
    end
  end

  # Guava `UnsignedBytes.parseUnsignedByte` and vanilla's `parseUnsignedShort`.
  defp unsigned_small(text, radix, bits) do
    with {:ok, value} <- java_parse(text, radix, @int_min..@int_max) do
      if Bitwise.bsr(value, bits) == 0,
        do:
          {:ok,
           if(value >= Bitwise.bsl(1, bits - 1), do: value - Bitwise.bsl(1, bits), else: value)},
        else: {:error, "out of range: #{value}"}
    end
  end

  defp unsigned_int(text, radix) do
    if String.length(text) <= 5 or (radix == 10 and String.length(text) <= 9) do
      java_parse(text, radix, @int_min..@int_max)
    else
      with {:ok, value} <- java_parse(text, radix, -0x8000000000000000..0x7FFFFFFFFFFFFFFF) do
        if Bitwise.band(value, -0x100000000) == 0,
          do: {:ok, if(value > @int_max, do: value - 0x100000000, else: value)},
          else: {:error, "String value #{text} exceeds range of unsigned int."}
      end
    end
  end

  defp unsigned_long(text, radix) do
    value = String.to_integer(text, radix)

    if value <= 0xFFFFFFFFFFFFFFFF,
      do: {:ok, if(value > 0x7FFFFFFFFFFFFFFF, do: value - 0x10000000000000000, else: value)},
      else: {:error, "String value #{text} exceeds range of unsigned long."}
  end

  defp java_parse(text, radix, range) do
    value = String.to_integer(text, radix)

    if value in range,
      do: {:ok, value},
      else:
        {:error,
         ~s(For input string: "#{text}") <> if(radix == 10, do: "", else: " under radix #{radix}")}
  end

  # ---- printing (`Tag.toString`, used in vanilla's codec messages) ----

  @doc "A tag as vanilla prints it in messages (SNBT)."
  def to_string({:byte, v}), do: "#{v}b"
  def to_string({:short, v}), do: "#{v}s"
  def to_string({:int, v}), do: "#{v}"
  def to_string({:long, v}), do: "#{v}L"
  def to_string({:float, <<v::float-32>>}), do: "#{Valimc.Text.Number.java(v, 32)}f"
  def to_string({:double, <<v::float-64>>}), do: "#{Valimc.Text.Number.java(v, 64)}d"
  def to_string({:string, text}), do: quote_string(text)

  def to_string({:list, _} = list),
    do: "[" <> Enum.map_join(Valimc.Data.NBT.items(list), ",", &__MODULE__.to_string/1) <> "]"

  def to_string({:compound, map}),
    do:
      "{" <>
        Enum.map_join(Enum.sort(map), ",", fn {k, v} ->
          key(k) <> ":" <> __MODULE__.to_string(v)
        end) <> "}"

  def to_string({:byte_array, bin}),
    do: "[B;" <> Enum.map_join(for(<<v::signed-8 <- bin>>, do: v), ",", &"#{&1}B") <> "]"

  def to_string({:int_array, bin}),
    do: "[I;" <> Enum.map_join(for(<<v::signed-32 <- bin>>, do: v), ",", &"#{&1}") <> "]"

  def to_string({:long_array, bin}),
    do: "[L;" <> Enum.map_join(for(<<v::signed-64 <- bin>>, do: v), ",", &"#{&1}L") <> "]"

  defp key(k),
    do:
      if(Regex.match?(~r/\A[A-Za-z._]+[A-Za-z0-9._+-]*\z/, k) and k not in ["true", "false"],
        do: k,
        else: quote_string(k)
      )

  defp quote_string(text) do
    quote =
      if String.contains?(text, "\"") and not String.contains?(text, "'"), do: "'", else: "\""

    escaped = text |> String.replace("\\", "\\\\") |> String.replace(quote, "\\" <> quote)
    quote <> escaped <> quote
  end
end
