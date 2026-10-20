defmodule Valimc.Command.Reader do
  @moduledoc """
  Brigadier's string reader over UTF-16 code units (VMC-053).

  Vanilla cursors, substrings and error contexts count Java `char`s, so commands
  are read as a tuple of UTF-16 code units. Readers are values; parsers return the
  advanced reader and raise syntax errors with `Valimc.Command.Error.throw!/1`.
  """
  alias Valimc.Command.Error

  defstruct [:units, :size, cursor: 0]

  def new(string) when is_binary(string) do
    units = for <<unit::16 <- :unicode.characters_to_binary(string, :utf8, :utf16)>>, do: unit
    tuple = List.to_tuple(units)
    %__MODULE__{units: tuple, size: tuple_size(tuple)}
  end

  def string(%__MODULE__{units: units, size: size}), do: substring(units, 0, size)
  def remaining(%__MODULE__{} = r), do: substring(r.units, r.cursor, r.size)
  def remaining_length(%__MODULE__{} = r), do: r.size - r.cursor

  @doc "Java `String.substring(from, to)` of the reader's text, in code units."
  def slice(%__MODULE__{units: units}, from, to), do: substring(units, from, to)

  defp substring(_units, from, to) when from >= to, do: ""

  defp substring(units, from, to) do
    binary = for i <- from..(to - 1), into: <<>>, do: <<elem(units, i)::16>>

    case :unicode.characters_to_binary(binary, :utf16, :utf8) do
      text when is_binary(text) -> text
      # A lone surrogate (a cut pair): Java keeps it; we show the replacement char.
      {_, good, _rest} -> good <> "�"
    end
  end

  def can_read?(%__MODULE__{cursor: c, size: s}, n \\ 1), do: c + n <= s
  def peek(%__MODULE__{units: u, cursor: c}, offset \\ 0), do: elem(u, c + offset)
  def skip(%__MODULE__{} = r), do: %{r | cursor: r.cursor + 1}
  def set_cursor(%__MODULE__{} = r, cursor), do: %{r | cursor: cursor}

  def read(%__MODULE__{} = r), do: {peek(r), skip(r)}

  def at?(r, char), do: can_read?(r) and peek(r) == char

  @doc "Java `Character.isWhitespace` for UTF-16 code units."
  def whitespace?(c) when c in 9..13 or c in 28..32, do: true
  def whitespace?(c) when c in [0x1680, 0x2028, 0x2029, 0x205F, 0x3000], do: true
  def whitespace?(c) when c in 0x2000..0x2006 or c in 0x2008..0x200A, do: true
  def whitespace?(_), do: false

  def skip_whitespace(r) do
    if can_read?(r) and whitespace?(peek(r)), do: skip_whitespace(skip(r)), else: r
  end

  defp number_char?(c), do: c in ?0..?9 or c == ?. or c == ?-

  def unquoted_char?(c),
    do: c in ?0..?9 or c in ?A..?Z or c in ?a..?z or c in [?_, ?-, ?., ?+]

  @doc "Advances while `fun` accepts the next unit; returns `{text, reader}`."
  def take_while(r, fun) do
    stop = scan(r, r.cursor, fun)
    {slice(r, r.cursor, stop), %{r | cursor: stop}}
  end

  defp scan(r, i, fun) do
    if i < r.size and fun.(elem(r.units, i)), do: scan(r, i + 1, fun), else: i
  end

  def read_int(r), do: read_number(r, :int)
  def read_long(r), do: read_number(r, :long)
  def read_double(r), do: read_number(r, :double)
  def read_float(r), do: read_number(r, :float)

  @expected %{int: "int", long: "long", double: "double", float: "float"}

  defp read_number(r, type) do
    start = r.cursor
    {text, r} = take_while(r, &number_char?/1)

    if text == "",
      do: Error.throw!(Error.with_context("parsing.#{@expected[type]}.expected", [], r))

    case parse_number(text, type) do
      {:ok, value} ->
        {value, r}

      :error ->
        Error.throw!(
          Error.with_context("parsing.#{@expected[type]}.invalid", [text], set_cursor(r, start))
        )
    end
  end

  @int_range -2_147_483_648..2_147_483_647
  @long_range -9_223_372_036_854_775_808..9_223_372_036_854_775_807

  @doc "Java `Integer/Long/Double/Float.parse*` for text of digits, dots and minus signs."
  def parse_number(text, type) when type in [:int, :long] do
    range = if type == :int, do: @int_range, else: @long_range

    with true <- Regex.match?(~r/\A-?\d+\z/, text),
         value = String.to_integer(text),
         true <- value in range do
      {:ok, value}
    else
      _ -> :error
    end
  end

  def parse_number(text, type) when type in [:double, :float] do
    case Regex.run(~r/\A(-?)(\d*)(?:\.(\d*))?\z/, text) do
      [_, sign | parts] ->
        int = Enum.at(parts, 0, "")
        frac = Enum.at(parts, 1, "")

        if int == "" and frac == "",
          do: :error,
          else: {:ok, decimal(sign, int, frac, type)}

      nil ->
        :error
    end
  end

  # Correctly rounded conversion of a plain decimal; huge values become ±infinity
  # (Java parses them as such) and float results round to the nearest float32.
  defp decimal(sign, int, frac, type) do
    digits = String.trim_leading(int <> frac, "0")
    negative = sign == "-"

    value =
      cond do
        digits == "" ->
          0.0

        String.length(String.trim_leading(int, "0")) > 400 ->
          :infinity

        true ->
          text = "#{if int == "", do: "0", else: int}.#{if frac == "", do: "0", else: frac}"

          try do
            String.to_float(text)
          rescue
            ArgumentError -> :infinity
          end
      end

    value =
      case {value, type} do
        {:infinity, _} -> :infinity
        {v, :float} -> to_float32(v)
        {v, :double} -> v
      end

    case {value, negative} do
      {:infinity, true} -> :neg_infinity
      {:infinity, false} -> :infinity
      {v, true} -> -v
      {v, false} -> v
    end
  end

  @doc "Rounds a double to the nearest float32 value (±infinity on overflow)."
  def to_float32(:infinity), do: :infinity
  def to_float32(:neg_infinity), do: :neg_infinity

  def to_float32(value) do
    case <<value::float-32>> do
      <<_sign::1, 0xFF::8, _::23>> -> if value > 0, do: :infinity, else: :neg_infinity
      <<f::float-32>> -> f
    end
  rescue
    ArgumentError -> if value > 0, do: :infinity, else: :neg_infinity
  end

  def read_unquoted_string(r), do: take_while(r, &unquoted_char?/1)

  def read_quoted_string(r) do
    cond do
      not can_read?(r) ->
        {"", r}

      peek(r) in [?", ?'] ->
        read_string_until(skip(r), peek(r))

      true ->
        Error.throw!(Error.with_context("parsing.quote.expected.start", [], r))
    end
  end

  def read_string_until(r, terminator), do: read_until(r, terminator, [], false)

  defp read_until(r, terminator, acc, escaped) do
    if can_read?(r) do
      {c, r} = read(r)

      cond do
        escaped and c != terminator and c != ?\\ ->
          r = set_cursor(r, r.cursor - 1)
          Error.throw!(Error.with_context("parsing.quote.escape", [units_text([c])], r))

        escaped ->
          read_until(r, terminator, [c | acc], false)

        c == ?\\ ->
          read_until(r, terminator, acc, true)

        c == terminator ->
          {units_text(Enum.reverse(acc)), r}

        true ->
          read_until(r, terminator, [c | acc], false)
      end
    else
      Error.throw!(Error.with_context("parsing.quote.expected.end", [], r))
    end
  end

  defp units_text(units) do
    binary = for u <- units, into: <<>>, do: <<u::16>>

    case :unicode.characters_to_binary(binary, :utf16, :utf8) do
      text when is_binary(text) -> text
      {_, good, _} -> good <> "�"
    end
  end

  def read_string(r) do
    cond do
      not can_read?(r) -> {"", r}
      peek(r) in [?", ?'] -> read_string_until(skip(r), peek(r))
      true -> read_unquoted_string(r)
    end
  end

  def read_boolean(r) do
    start = r.cursor
    {value, r} = read_string(r)

    case value do
      "" ->
        Error.throw!(Error.with_context("parsing.bool.expected", [], r))

      "true" ->
        {true, r}

      "false" ->
        {false, r}

      other ->
        Error.throw!(Error.with_context("parsing.bool.invalid", [other], set_cursor(r, start)))
    end
  end

  def expect(r, char) do
    if at?(r, char),
      do: skip(r),
      else: Error.throw!(Error.with_context("parsing.expected", [<<char::utf8>>], r))
  end
end
