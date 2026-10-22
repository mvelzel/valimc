defmodule Valimc.Text.Codec do
  @moduledoc """
  Vanilla's text component codec (`ComponentSerialization.CODEC`) over NBT
  tags, one module for every reader of text (VMC-077o).

  - `decode/1` reads a component as the command `component` argument does
    (VMC-053i), with DFU's error messages, into a normalised compound ready to
    resolve and send. A component is a string, a non-empty list (first element
    plus siblings) or a compound whose contents are chosen by `type` or,
    without it, by the first of text, translatable, keybind, score, selector,
    nbt and object that decodes, with optional `extra` and the style fields.
    Errors follow DFU: `either` reports a partial branch's error alone, else
    `Failed to parse either. First: ...; Second: ...`; records and lists list
    failures last first.
  - `check/1`, `identity_key/1` and the lore variants bound and validate item
    text (custom names, item names, lore) and give its semantic identity:
    contents, resolved style and siblings, so stacks whose text means the
    same compare equal. Click and hover events, scores, selectors, NBT and
    object contents are `:unsupported` on items. `take/1` and `encode/1` read
    and write it on the wire.
  """
  import Bitwise
  alias Valimc.Text.Snbt
  alias Valimc.Data.NBT
  alias Valimc.Protocol.Wire

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

  # ---- decode (command arguments) ----

  @doc "`{:ok, component}` or `{:error, message}`."
  def decode(tag) do
    case component(tag) do
      {:ok, value} -> {:ok, value}
      {:error, message, _partial} -> {:error, message}
    end
  end

  # Component := either(either(STRING, nonEmptyList(Component)), FULL)
  defp component(tag) do
    either(fn -> either(fn -> string(tag) end, fn -> list(tag) end) end, fn -> full(tag) end)
  end

  defp either(first, second) do
    case first.() do
      {:ok, value} ->
        {:ok, value}

      {:error, a, a_partial} ->
        case second.() do
          {:ok, value} ->
            {:ok, value}

          {:error, _b, _} when a_partial ->
            {:error, a, true}

          {:error, b, true} ->
            {:error, b, true}

          {:error, b, false} ->
            {:error, "Failed to parse either. First: #{a}; Second: #{b}", false}
        end
    end
  end

  defp string({:string, text}), do: {:ok, {:compound, %{"text" => {:string, text}}}}
  defp string(_), do: {:error, "Not a string", false}

  defp list({:list, _} = list) do
    elements = NBT.items(list)
    results = Enum.map(elements, &component/1)
    errors = for {:error, message, _} <- Enum.reverse(results), do: message
    # `nonEmptyList` validates the decoded (successful) elements.
    successes = Enum.count(results, &match?({:ok, _}, &1))
    errors = if successes == 0, do: errors ++ ["List must have contents"], else: errors

    if errors == [] do
      [first | rest] = Enum.map(results, fn {:ok, value} -> value end)
      {:ok, Enum.reduce(rest, first, &add_extra(&2, &1))}
    else
      # A list with some decoded elements is a partial result.
      {:error, Enum.join(errors, "; "), successes > 0}
    end
  end

  defp list(tag), do: {:error, "Not a list: #{Snbt.to_string(tag)}", false}

  defp add_extra({:compound, fields}, child) do
    extra =
      case fields["extra"] do
        nil -> [child]
        list -> NBT.items(list) ++ [child]
      end

    {:compound, Map.put(fields, "extra", NBT.list(extra))}
  end

  # FULL := record{contents, extra, style}; partial once the contents decode.
  defp full({:compound, fields} = tag) do
    case contents(fields, tag) do
      {:ok, contents} ->
        errors =
          Enum.reverse(style_errors(fields)) ++ extra_errors(fields)

        if errors == [] do
          {:ok,
           {:compound,
            Map.merge(
              contents,
              Map.take(normalised_style(fields), keys(fields)) |> Map.merge(extra(fields))
            )}}
        else
          {:error, Enum.join(errors, "; "), true}
        end

      {:error, message} ->
        {:error, message, false}
    end
  end

  defp full(tag), do: {:error, "Not a map: #{Snbt.to_string(tag)}", false}

  defp keys(fields), do: Map.keys(fields)

  # ---- decode: contents ----

  @types ~w(text translatable keybind score selector nbt object)

  defp contents(fields, tag) do
    case fields["type"] do
      nil ->
        Enum.find_value(@types, {:error, "No matching codec found"}, fn type ->
          case content(type, fields, tag) do
            {:ok, value} -> {:ok, value}
            _ -> nil
          end
        end)

      {:string, type} when type in @types ->
        content(type, fields, tag)

      {:string, type} ->
        {:error, "Unknown element id: #{type}"}

      _ ->
        {:error, "Not a string"}
    end
  end

  defp content("text", fields, tag),
    do: required(fields, tag, "text", &string_field/1, &%{"text" => &1})

  defp content("keybind", fields, tag),
    do: required(fields, tag, "keybind", &string_field/1, &%{"keybind" => &1})

  defp content("translatable", fields, tag) do
    with {:ok, key} <- required(fields, tag, "translate", &string_field/1, & &1),
         {:ok, args} <- with_args(fields["with"]) do
      base = %{"translate" => key}

      base =
        if match?({:string, _}, fields["fallback"]),
          do: Map.put(base, "fallback", fields["fallback"]),
          else: base

      {:ok, if(args, do: Map.put(base, "with", args), else: base)}
    end
  end

  defp content("score", fields, tag) do
    with {:ok, {:compound, score}} <- required(fields, tag, "score", &map_field/1, & &1),
         {:ok, name} <- required(score, {:compound, score}, "name", &string_field/1, & &1),
         {:ok, objective} <-
           required(score, {:compound, score}, "objective", &string_field/1, & &1) do
      {:ok, %{"score" => {:compound, %{"name" => name, "objective" => objective}}}}
    end
  end

  defp content("selector", fields, tag) do
    with {:ok, {:string, text} = selector} <-
           required(fields, tag, "selector", &string_field/1, & &1),
         {:ok, _} <- parse_selector(text),
         {:ok, separator} <- optional_component(fields["separator"]) do
      base = %{"selector" => selector}
      {:ok, if(separator, do: Map.put(base, "separator", separator), else: base)}
    end
  end

  defp content("nbt", fields, tag) do
    with {:ok, path} <- required(fields, tag, "nbt", &string_field/1, & &1) do
      sources = Map.take(fields, ~w(block entity storage interpret separator))
      {:ok, Map.merge(%{"nbt" => path}, sources)}
    end
  end

  defp content("object", fields, _tag) do
    cond do
      Map.has_key?(fields, "sprite") or Map.has_key?(fields, "player") ->
        {:ok, Map.take(fields, ~w(object atlas sprite player hat))}

      true ->
        {:error, "No matching codec found"}
    end
  end

  defp parse_selector(text) do
    reader = Valimc.Text.Reader.new(text)

    case Valimc.Text.Error.catching(fn -> Valimc.Commands.Parser.Selector.parse(reader, true) end) do
      {:ok, {_selector, after_selector}} ->
        if Valimc.Text.Reader.can_read?(after_selector),
          do: {:error, "Invalid selector component: #{text}"},
          else: {:ok, text}

      {:error, _} ->
        {:error, "Invalid selector component: #{text}"}
    end
  end

  defp required(fields, tag, key, decode, wrap) do
    case fields[key] do
      nil ->
        {:error, "No key #{key} in MapLike[#{Snbt.to_string(tag)}]"}

      value ->
        case decode.(value) do
          {:ok, value} -> {:ok, wrap.(value)}
          error -> error
        end
    end
  end

  defp string_field({:string, _} = value), do: {:ok, value}
  defp string_field(_), do: {:error, "Not a string"}

  defp map_field({:compound, _} = value), do: {:ok, value}
  defp map_field(tag), do: {:error, "Not a map: #{Snbt.to_string(tag)}"}

  defp optional_component(nil), do: {:ok, nil}

  defp optional_component(tag) do
    case component(tag) do
      {:ok, value} -> {:ok, value}
      {:error, message, _} -> {:error, message}
    end
  end

  # `with`: primitives (strings, numbers, booleans) stay as they are; the rest are components.
  defp with_args(nil), do: {:ok, nil}

  defp with_args({:list, _} = list) do
    list
    |> NBT.items()
    |> Enum.reduce_while({:ok, []}, fn
      {type, _} = primitive, {:ok, acc}
      when type in [:string, :byte, :short, :int, :long, :float, :double] ->
        {:cont, {:ok, [primitive | acc]}}

      tag, {:ok, acc} ->
        case component(tag) do
          {:ok, value} -> {:cont, {:ok, [value | acc]}}
          {:error, message, _} -> {:halt, {:error, message}}
        end
    end)
    |> case do
      {:ok, args} -> {:ok, NBT.list(Enum.reverse(args))}
      error -> error
    end
  end

  defp with_args(tag), do: {:error, "Not a list: #{Snbt.to_string(tag)}"}

  # ---- decode: extra and style ----

  defp extra_errors(fields) do
    case fields["extra"] do
      nil ->
        []

      {:list, _} = list ->
        case list(list) do
          {:ok, _} -> []
          {:error, message, _} -> [message]
        end

      tag ->
        ["Not a list: #{Snbt.to_string(tag)}"]
    end
  end

  defp extra(fields) do
    case fields["extra"] do
      nil ->
        %{}

      list ->
        %{
          "extra" => NBT.list(Enum.map(NBT.items(list), fn tag -> elem(component(tag), 1) end))
        }
    end
  end

  # Style fields in `Style.Serializer` order; their errors, first field first.
  defp style_errors(fields) do
    Enum.flat_map(
      ["color", "shadow_color"] ++
        @booleans ++ ["click_event", "hover_event", "insertion", "font"],
      fn key ->
        case fields[key] do
          nil -> []
          value -> List.wrap(style_error(key, value))
        end
      end
    )
  end

  # `TextColor.parseColor`: `#` and Java `Integer.parseInt(hex, 16)` within RGB, or a name.
  defp style_error("color", {:string, "#" <> hex = color}) do
    case java_hex(hex) do
      {:ok, value} when value in 0..0xFFFFFF -> nil
      {:ok, _} -> "Color value out of range: #{color}"
      :error -> "Invalid color value: #{color}"
    end
  end

  defp style_error("color", {:string, color}),
    do: if(Map.has_key?(@colors, color), do: nil, else: "Invalid color name: #{color}")

  defp style_error("color", _), do: "Not a string"

  defp style_error("shadow_color", {type, _}) when type in [:int, :byte, :short, :long], do: nil

  defp style_error("shadow_color", {:list, {type, [_, _, _, _]}}) when type in [:float, :double],
    do: nil

  defp style_error("shadow_color", _), do: "Not a number"

  defp style_error(key, {type, _})
       when key in @booleans and type in [:byte, :short, :int, :long, :float, :double], do: nil

  defp style_error(key, _) when key in @booleans, do: "Not a number"
  defp style_error("insertion", {:string, _}), do: nil
  defp style_error("insertion", _), do: "Not a string"
  defp style_error("font", {:string, _}), do: nil
  defp style_error("font", _), do: "Not a string"
  defp style_error("click_event", tag), do: click_event(tag)
  defp style_error("hover_event", tag), do: hover_event(tag)

  defp java_hex(text) do
    with true <- Regex.match?(~r/\A[+-]?[0-9A-Fa-f]+\z/, text),
         value = String.to_integer(String.replace_prefix(text, "+", ""), 16),
         true <- value in -0x80000000..0x7FFFFFFF do
      {:ok, value}
    else
      _ -> :error
    end
  end

  @clicks %{
    "open_url" => "url",
    "open_file" => "path",
    "run_command" => "command",
    "suggest_command" => "command",
    "change_page" => "page",
    "copy_to_clipboard" => "value",
    "show_dialog" => "dialog",
    "custom" => "id"
  }

  defp click_event({:compound, fields} = tag) do
    case fields["action"] do
      nil ->
        "No key action in MapLike[#{Snbt.to_string(tag)}]"

      {:string, action} when is_map_key(@clicks, action) ->
        key = @clicks[action]

        case fields[key] do
          nil ->
            "No key #{key} in MapLike[#{Snbt.to_string(tag)}]"

          {:string, _} when key != "page" ->
            nil

          {type, page} when key == "page" and type in [:byte, :short, :int, :long] and page > 0 ->
            nil

          {type, page} when key == "page" and type in [:byte, :short, :int, :long] ->
            "Value must be positive: #{page}"

          _ when key == "page" ->
            "Not a number"

          _ ->
            "Not a string"
        end

      {:string, action} ->
        "Unknown element name:#{action}"

      _ ->
        "Not a string"
    end
  end

  defp click_event(tag), do: "Not a map: #{Snbt.to_string(tag)}"

  defp hover_event({:compound, fields} = tag) do
    case fields["action"] do
      nil ->
        "No key action in MapLike[#{Snbt.to_string(tag)}]"

      {:string, "show_text"} ->
        case fields["value"] do
          nil ->
            "No key value in MapLike[#{Snbt.to_string(tag)}]"

          value ->
            case component(value) do
              {:ok, _} -> nil
              {:error, message, _} -> message
            end
        end

      {:string, "show_item"} ->
        case fields["id"] do
          nil -> "No key id in MapLike[#{Snbt.to_string(tag)}]"
          {:string, _} -> nil
          _ -> "Not a string"
        end

      {:string, "show_entity"} ->
        cond do
          fields["id"] == nil -> "No key id in MapLike[#{Snbt.to_string(tag)}]"
          fields["uuid"] == nil -> "No key uuid in MapLike[#{Snbt.to_string(tag)}]"
          true -> nil
        end

      {:string, action} ->
        "Unknown element name:#{action}"

      _ ->
        "Not a string"
    end
  end

  defp hover_event(tag), do: "Not a map: #{Snbt.to_string(tag)}"

  # Style fields pass through as given; show_text values are normalised components.
  defp normalised_style(fields) do
    fields
    |> Map.take(["color", "shadow_color", "click_event", "insertion", "font" | @booleans])
    |> Map.new(fn
      {key, {type, value}} when key in @booleans and type in [:float, :double] ->
        {key, {:byte, if(value == <<0::size(byte_size(value) * 8)>>, do: 0, else: 1)}}

      {key, {_type, value}} when key in @booleans ->
        {key, {:byte, if(value != 0, do: 1, else: 0)}}

      pair ->
        pair
    end)
    |> then(fn style ->
      case fields["hover_event"] do
        {:compound, %{"action" => {:string, "show_text"}, "value" => value} = hover} ->
          Map.put(
            style,
            "hover_event",
            {:compound, Map.put(hover, "value", elem(component(value), 1))}
          )

        nil ->
          style

        hover ->
          Map.put(style, "hover_event", hover)
      end
    end)
  end

  # ---- items: bounds, validity and identity ----

  def check(tag),
    do:
      protect(fn ->
        bounded([tag])
        semantic(tag)
      end)

  def check_lore(lines),
    do:
      protect(fn ->
        bounded_lore(lines)
        Enum.map(lines, &semantic/1)
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

  # ---- identity: vanilla's component semantics as a comparable key ----

  defp semantic({:string, text}), do: {{:text, text}, %{}, []}

  defp semantic({:compound, fields}) do
    contents = semantic_contents(fields)
    style = semantic_style(fields)

    extra =
      case Map.fetch(fields, "extra") do
        :error -> []
        {:ok, tag} -> tag |> sequence() |> nonempty!() |> Enum.map(&semantic/1)
      end

    {contents, style, extra}
  end

  defp semantic(tag) do
    [first | others] = tag |> sequence() |> nonempty!() |> Enum.map(&semantic/1)
    {contents, style, siblings} = first
    {contents, style, siblings ++ others}
  end

  defp semantic_contents(fields) do
    case Map.fetch(fields, "type") do
      {:ok, {:string, type}} -> semantic_contents(type, fields)
      {:ok, _} -> fail(:invalid_text)
      :error -> semantic_legacy(fields)
    end
  end

  defp semantic_legacy(fields) do
    # Vanilla tries complete content codecs in order, not just matching field names.
    key =
      Enum.reduce_while(~w(text translatable keybind), :none, fn type, _ ->
        case protect(fn -> semantic_contents(type, fields) end) do
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

  defp semantic_contents(type, fields) do
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
            {:ok, value} -> Enum.map(sequence(value), &semantic_argument/1)
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

  defp semantic_argument({:string, value}), do: {:string, value}

  defp semantic_argument({type, _} = tag) when type in @numbers,
    do: {:number, type, NBT.identity_key(tag)}

  defp semantic_argument(tag) do
    case semantic(tag) do
      {{:text, value}, style, []} when map_size(style) == 0 -> {:string, value}
      key -> {:component, key}
    end
  end

  defp semantic_style(fields) do
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
          field == "color" -> color_value(string!(tag))
          field == "shadow_color" -> shadow(tag)
          field == "insertion" -> string!(tag)
          field == "font" -> font(string!(tag))
        end

      {field, value}
    end
  end

  defp color_value("#" <> hex) do
    case Integer.parse(hex, 16) do
      {value, ""} when value in 0..0xFFFFFF -> value
      _ -> fail(:invalid_text_color)
    end
  end

  defp color_value(name), do: Map.get(@colors, name) || fail(:invalid_text_color)

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
  defp sequence({:list, _} = list), do: NBT.items(list)
  defp sequence({:byte_array, bytes}), do: for(<<value::signed-8 <- bytes>>, do: {:byte, value})
  defp sequence({:int_array, bytes}), do: for(<<value::signed-32 <- bytes>>, do: {:int, value})
  defp sequence({:long_array, bytes}), do: for(<<value::signed-64 <- bytes>>, do: {:long, value})
  defp sequence(_), do: fail(:invalid_text_list)
  defp nonempty!([]), do: fail(:empty_text_list)
  defp nonempty!(values), do: values
  defp require!(true, _), do: :ok
  defp require!(false, reason), do: fail(reason)
  defp fail(reason), do: throw({:text_error, reason})
end
