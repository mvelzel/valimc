defmodule Valimc.Protocol.TextComponent do
  @moduledoc "Bounded vanilla text semantics, separate from the retained network NBT."
  import Bitwise
  alias Valimc.Protocol.{NBT, Wire}

  @booleans ~w(bold italic underlined strikethrough obfuscated)
  @colors Map.new(
            Enum.zip(
              ~w(black dark_blue dark_green dark_aqua dark_red dark_purple gold gray dark_gray blue green aqua red light_purple yellow white),
              [
                0x000000,
                0x0000AA,
                0x00AA00,
                0x00AAAA,
                0xAA0000,
                0xAA00AA,
                0xFFAA00,
                0xAAAAAA,
                0x555555,
                0x5555FF,
                0x55FF55,
                0x55FFFF,
                0xFF5555,
                0xFF55FF,
                0xFFFF55,
                0xFFFFFF
              ]
            )
          )
  @numbers [:byte, :short, :int, :long, :float, :double]

  def check(tag),
    do:
      protect(fn ->
        bounded([tag])
        component(tag)
      end)

  def check_lore(lines),
    do:
      protect(fn ->
        bounded_lore(lines)
        Enum.map(lines, &component/1)
      end)

  def identity_key(tag), do: key!(check(tag))
  def lore_key(lines), do: key!(check_lore(lines))
  def valid?(tag), do: match?({:ok, _}, check(tag))
  def valid_lore?(lines), do: match?({:ok, _}, check_lore(lines))

  def take(bytes) do
    with {:ok, tag, rest} <- NBT.take(bytes) do
      {checked_value(check(tag), tag), rest}
    else
      {:error, reason} -> fail({:nbt, reason})
    end
  end

  def take_lore(bytes) do
    {count, rest} = Wire.take_varint(bytes)
    require!(count in 0..256, :lore_line_limit)
    {lines, rest, _} = read_lines(rest, count, [], byte_size(bytes), 1024)
    {checked_value(check_lore(lines), lines), rest}
  end

  def encode(tag) do
    identity_key(tag)
    NBT.encode(tag)
  end

  def encode_lore(lines) do
    lore_key(lines)
    [Wire.varint(length(lines)), Enum.map(lines, &NBT.encode/1)]
  end

  defp key!({:ok, key}), do: key
  defp key!(:unsupported), do: fail(:unsupported_text)
  defp key!({:error, reason}), do: fail(reason)
  defp checked_value({:ok, _}, value), do: value
  defp checked_value(:unsupported, _), do: :unsupported
  defp checked_value({:error, reason}, _), do: fail(reason)

  defp protect(fun) do
    {:ok, fun.()}
  rescue
    _ in [ArgumentError, MatchError, FunctionClauseError] -> {:error, :invalid_text}
  catch
    {:text_error, :unsupported_text} -> :unsupported
    {:text_error, reason} -> {:error, reason}
    {:nbt_error, reason} -> {:error, {:nbt, reason}}
  end

  defp bounded_lore(lines) do
    require!(is_list(lines) and length(lines) <= 256, :lore_line_limit)
    bounded(lines)
  end

  defp bounded(tags) do
    Enum.reduce(tags, {65_536, 1024}, fn tag, {bytes, nodes} ->
      size = IO.iodata_length(NBT.encode(tag))
      require!(size <= bytes, :text_byte_limit)
      {bytes - size, count_nodes(tag, nodes)}
    end)
  end

  defp count_nodes(tag, nodes) do
    require!(nodes > 0, :text_node_limit)
    nodes = nodes - 1

    case tag do
      {:compound, values} ->
        Enum.reduce(values, nodes, fn {_, child}, n -> count_nodes(child, n) end)

      {:list, {type, values}} ->
        Enum.reduce(values, nodes, &count_nodes({type, &1}, &2))

      {type, bytes} when type in [:byte_array, :int_array, :long_array] ->
        width = %{byte_array: 1, int_array: 4, long_array: 8}[type]
        remaining = nodes - div(byte_size(bytes), width)
        require!(remaining >= 0, :text_node_limit)
        remaining

      _ ->
        nodes
    end
  end

  defp read_lines(bytes, 0, lines, _, _), do: {Enum.reverse(lines), bytes, :ok}

  defp read_lines(bytes, count, lines, size, nodes) do
    require!(size - byte_size(bytes) <= 65_536, :text_byte_limit)

    case NBT.take(bytes) do
      {:ok, tag, rest} ->
        require!(size - byte_size(rest) <= 65_536, :text_byte_limit)
        read_lines(rest, count - 1, [tag | lines], size, count_nodes(tag, nodes))

      {:error, reason} ->
        fail({:nbt, reason})
    end
  end

  defp component({:string, text}), do: {{:text, text}, %{}, []}

  defp component({:compound, fields}) do
    contents = contents(fields)
    style = style(fields)

    extra =
      case Map.fetch(fields, "extra") do
        :error -> []
        {:ok, tag} -> tag |> sequence() |> nonempty!() |> Enum.map(&component/1)
      end

    {contents, style, extra}
  end

  defp component(tag) do
    [first | others] = tag |> sequence() |> nonempty!() |> Enum.map(&component/1)
    {contents, style, siblings} = first
    {contents, style, siblings ++ others}
  end

  defp contents(fields) do
    case Map.fetch(fields, "type") do
      {:ok, {:string, type}} -> contents(type, fields)
      {:ok, _} -> fail(:invalid_text)
      :error -> legacy_contents(fields)
    end
  end

  defp legacy_contents(fields) do
    # Vanilla tries complete content codecs in order, not just matching field names.
    key =
      Enum.reduce_while(~w(text translatable keybind), :none, fn type, _ ->
        case protect(fn -> contents(type, fields) end) do
          {:ok, key} -> {:halt, key}
          :unsupported -> fail(:unsupported_text)
          {:error, _} -> {:cont, :none}
        end
      end)

    if key == :none do
      if Enum.any?(~w(score selector nbt object), &Map.has_key?(fields, &1)),
        do: fail(:unsupported_text),
        else: fail(:invalid_text)
    else
      key
    end
  end

  defp contents(type, fields) do
    case type do
      "text" ->
        {:text, string!(fields["text"])}

      "translatable" ->
        key = string!(fields["translate"])

        fallback =
          case fields["fallback"] do
            {:string, value} -> value
            _ -> nil
          end

        args =
          case Map.fetch(fields, "with") do
            :error -> []
            {:ok, value} -> Enum.map(sequence(value), &argument/1)
          end

        {:translate, key, fallback, args}

      "keybind" ->
        {:keybind, string!(fields["keybind"])}

      type when type in ~w(score selector nbt object) ->
        fail(:unsupported_text)

      _ ->
        fail(:invalid_text)
    end
  end

  defp argument({:string, value}), do: {:string, value}

  defp argument({type, _} = tag) when type in @numbers,
    do: {:number, type, NBT.identity_key(tag)}

  defp argument(tag) do
    case component(tag) do
      {{:text, value}, style, []} when map_size(style) == 0 -> {:string, value}
      key -> {:component, key}
    end
  end

  defp style(fields) do
    require!(
      not Enum.any?(~w(click_event hover_event), &Map.has_key?(fields, &1)),
      :unsupported_text
    )

    for field <- @booleans ++ ~w(color shadow_color insertion font),
        Map.has_key?(fields, field),
        into: %{} do
      tag = fields[field]

      value =
        cond do
          field in @booleans -> number!(tag) != 0
          field == "color" -> color(string!(tag))
          field == "shadow_color" -> shadow(tag)
          field == "insertion" -> string!(tag)
          field == "font" -> font(string!(tag))
        end

      {field, value}
    end
  end

  defp color("#" <> hex) do
    case Integer.parse(hex, 16) do
      {value, ""} when value in 0..0xFFFFFF -> value
      _ -> fail(:invalid_text_color)
    end
  end

  defp color(name), do: Map.get(@colors, name) || fail(:invalid_text_color)

  defp font(value) do
    {namespace, path} =
      case String.split(value, ":", parts: 2) do
        [path] -> {"minecraft", path}
        ["", path] -> {"minecraft", path}
        [ns, path] -> {ns, path}
      end

    require!(
      Regex.match?(~r/\A[a-z0-9_.-]+\z/, namespace) and
        Regex.match?(~r/\A[a-z0-9_\/.\-]*\z/, path),
      :invalid_text_font
    )

    namespace <> ":" <> path
  end

  defp shadow({type, _} = tag) when type in @numbers, do: int32(number!(tag), type)

  defp shadow(tag) do
    [r, g, b, a] = Enum.map(sequence(tag), &channel/1)
    signed32(a <<< 24 ||| r <<< 16 ||| g <<< 8 ||| b)
  end

  defp channel(tag) do
    value = float32(number!(tag))
    product = if is_number(value), do: float32(value * 255.0), else: value
    integer = int32(product, :float)
    # Mth.floor subtracts one from the Java float-to-int cast for negative fractions.
    integer =
      if product == :negative_infinity or (is_number(product) and product < integer),
        do: signed32(integer - 1),
        else: integer

    integer &&& 255
  end

  defp float32(value) when is_number(value) do
    {:float, raw} = NBT.float(value)
    number!({:float, raw})
  end

  defp float32(value), do: value

  defp int32(value, type) when type in [:byte, :short, :int, :long], do: signed32(value)
  defp int32(:nan, _), do: 0
  defp int32(:positive_infinity, _), do: 2_147_483_647
  defp int32(:negative_infinity, _), do: -2_147_483_648
  defp int32(value, _), do: min(2_147_483_647, max(-2_147_483_648, trunc(value)))

  defp signed32(value) do
    <<number::signed-32>> = <<value &&& 0xFFFFFFFF::32>>
    number
  end

  defp number!({type, value}) when type in [:byte, :short, :int, :long], do: value
  defp number!({:float, <<sign::1, 255::8, mantissa::23>>}), do: special(sign, mantissa)
  defp number!({:double, <<sign::1, 2047::11, mantissa::52>>}), do: special(sign, mantissa)
  defp number!({:float, <<value::float-32>>}), do: value
  defp number!({:double, <<value::float-64>>}), do: value
  defp number!(_), do: fail(:invalid_text_number)
  defp special(_, mantissa) when mantissa != 0, do: :nan
  defp special(0, 0), do: :positive_infinity
  defp special(1, 0), do: :negative_infinity
  defp string!({:string, value}), do: value
  defp string!(_), do: fail(:invalid_text)

  # ListTag's mixed-type network representation wraps primitive entries in "".
  defp sequence({:list, {type, values}}), do: Enum.map(values, &unwrap({type, &1}))
  defp sequence({:byte_array, bytes}), do: for(<<value::signed-8 <- bytes>>, do: {:byte, value})
  defp sequence({:int_array, bytes}), do: for(<<value::signed-32 <- bytes>>, do: {:int, value})
  defp sequence({:long_array, bytes}), do: for(<<value::signed-64 <- bytes>>, do: {:long, value})
  defp sequence(_), do: fail(:invalid_text_list)
  defp unwrap({:compound, %{"" => value} = fields}) when map_size(fields) == 1, do: value
  defp unwrap(tag), do: tag
  defp nonempty!([]), do: fail(:empty_text_list)
  defp nonempty!(values), do: values
  defp require!(true, _), do: :ok
  defp require!(false, reason), do: fail(reason)
  defp fail(reason), do: throw({:text_error, reason})
end
