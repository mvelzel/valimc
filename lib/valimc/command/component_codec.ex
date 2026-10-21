defmodule Valimc.Command.ComponentCodec do
  @moduledoc """
  Vanilla's text component codec over SNBT tags (VMC-053i), for the `component`
  argument: `ComponentSerialization.CODEC` with DFU's error messages.

  A component is a string, a non-empty list (first element plus siblings) or a
  compound whose contents are chosen by `type` or, without it, by the first of
  text, translatable, keybind, score, selector, nbt and object that decodes,
  with optional `extra` and the style fields. Decoding yields a normalised
  compound (`text`/`translate`/... plus `extra` and style) ready to resolve and
  send. Errors follow DFU: `either` reports a partial branch's error alone, else
  `Failed to parse either. First: ...; Second: ...`; records and lists list
  failures last first.
  """
  alias Valimc.Command.Snbt

  @colors ~w(black dark_blue dark_green dark_aqua dark_red dark_purple gold gray dark_gray blue green aqua red light_purple yellow white)
  @booleans ~w(bold italic underlined strikethrough obfuscated)

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
    elements = list_tags(list)
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
        list -> list_tags(list) ++ [child]
      end

    {:compound, Map.put(fields, "extra", Valimc.NBT.list(extra))}
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

  # ---- contents ----

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
    reader = Valimc.Command.Reader.new(text)

    case Valimc.Command.Error.catching(fn -> Valimc.Command.Selector.parse(reader, true) end) do
      {:ok, {_selector, after_selector}} ->
        if Valimc.Command.Reader.can_read?(after_selector),
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
    |> list_tags()
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
      {:ok, args} -> {:ok, Valimc.NBT.list(Enum.reverse(args))}
      error -> error
    end
  end

  defp with_args(tag), do: {:error, "Not a list: #{Snbt.to_string(tag)}"}

  # ---- extra and style ----

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
          "extra" =>
            Valimc.NBT.list(Enum.map(list_tags(list), fn tag -> elem(component(tag), 1) end))
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
    do: if(color in @colors, do: nil, else: "Invalid color name: #{color}")

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

  defp list_tags({:list, {:compound, values}}),
    do:
      Enum.map(values, fn
        %{"" => tag} = f when map_size(f) == 1 -> tag
        f -> {:compound, f}
      end)

  defp list_tags({:list, {type, values}}), do: Enum.map(values, &{type, &1})
end
