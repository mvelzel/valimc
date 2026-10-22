defmodule Valimc.Text do
  @moduledoc """
  Server-authored text components (VMC-053, VMC-077o), as network NBT: command
  feedback, disconnect reasons, join and death messages. One text model:
  `Valimc.Text.Codec` reads and validates components, `Valimc.Text.Render`
  prints them in English.

  Builders mirror vanilla's `Component` constructors so the client decodes the
  same component structure vanilla sends: `literal/1`, `translatable/2`
  (`translatableEscape`: strings and numbers stay primitive arguments), `empty/0`,
  `append/2` (siblings) and `style/2`.
  """
  alias Valimc.Data.NBT

  def literal(text) when is_binary(text), do: {:compound, %{"text" => {:string, text}}}
  def empty, do: literal("")

  def translatable(key, args \\ []) do
    fields = %{"translate" => {:string, key}}

    if args == [],
      do: {:compound, fields},
      else: {:compound, Map.put(fields, "with", with_args(args))}
  end

  defp with_args(args), do: NBT.list(Enum.map(args, &arg/1))

  @doc "A translation argument: binaries and numbers stay primitive, tags are components."
  def arg(value) when is_binary(value), do: {:string, value}

  def arg(value) when is_integer(value) and value in -2_147_483_648..2_147_483_647,
    do: {:int, value}

  def arg(value) when is_integer(value), do: {:long, value}
  def arg({:long, value}), do: {:long, value}
  def arg({:float, value}), do: {:float, float_bytes(value, 32)}
  def arg({:double, value}), do: {:double, float_bytes(value, 64)}
  def arg(value) when is_float(value), do: {:double, float_bytes(value, 64)}
  def arg({:compound, _} = tag), do: tag

  defp float_bytes(:infinity, 32), do: <<0x7F800000::32>>
  defp float_bytes(:neg_infinity, 32), do: <<0xFF800000::32>>
  defp float_bytes(:infinity, 64), do: <<0x7FF0000000000000::64>>
  defp float_bytes(:neg_infinity, 64), do: <<0xFFF0000000000000::64>>
  defp float_bytes(value, bits), do: <<value / 1::float-size(bits)>>

  def append({:compound, fields}, child) do
    extra =
      case fields["extra"] do
        nil -> [child]
        {:list, {_, _}} = list -> NBT.items(list) ++ [child]
      end

    {:compound, Map.put(fields, "extra", NBT.list(extra))}
  end

  @doc "Merges style fields (`color`, `bold`, `click_event`, ...) where unset, like `withStyle`."
  def style({:compound, fields}, styles) do
    {:compound,
     Enum.reduce(styles, fields, fn {key, value}, acc -> Map.put(acc, key, style_value(value)) end)}
  end

  defp style_value(value) when is_binary(value), do: {:string, value}
  defp style_value(value) when is_boolean(value), do: {:byte, if(value, do: 1, else: 0)}
  defp style_value({_, _} = tag), do: tag

  def color(component, color), do: style(component, [{"color", color}])

  @doc """
  `ComponentUtils.formatList`: nothing, the one component, or the components
  as siblings of an empty one with `separator` (a gray ", ") between them.
  """
  def join(components, separator \\ literal(", ") |> color("gray"))
  def join([], _separator), do: empty()
  def join([one], _separator), do: one

  def join([first | rest], separator),
    do: Enum.reduce(rest, empty() |> append(first), &(&2 |> append(separator) |> append(&1)))

  def suggest_command(command),
    do: {:compound, %{"action" => {:string, "suggest_command"}, "command" => {:string, command}}}

  @doc "A player's display name: insertion, `/tell` suggestion and entity hover."
  def player_name(name, uuid) do
    <<a::32, b::32, c::32, d::32>> = uuid

    literal(name)
    |> style([
      {"insertion", name},
      {"click_event", suggest_command("/tell #{name} ")},
      {"hover_event",
       {:compound,
        %{
          "action" => {:string, "show_entity"},
          "id" => {:string, "minecraft:player"},
          "uuid" => {:int_array, <<a::32, b::32, c::32, d::32>>},
          "name" => literal(name)
        }}}
    ])
  end

  def encode(tag), do: %Valimc.Protocol.ServerText{tag: tag}

  @doc "A component's plain text (`Component.getString`) for literal text and its siblings."
  def plain({:compound, fields}) do
    own =
      case fields do
        %{"text" => {:string, text}} -> text
        %{"translate" => {:string, key}} -> key
        _ -> ""
      end

    case fields["extra"] do
      nil -> own
      list -> own <> Enum.map_join(NBT.items(list), &plain/1)
    end
  end

  def plain({:string, text}), do: text
  def plain(_), do: ""

  @doc "The component as JSON terms, for the login phase, which sends text as JSON."
  def to_json({:compound, fields}),
    do: Map.new(fields, fn {key, value} -> {key, json_value(key, value)} end)

  defp json_value(key, {:byte, value})
       when key in ~w(bold italic underlined strikethrough obfuscated),
       do: value != 0

  defp json_value(_key, {:compound, _} = tag), do: to_json(tag)
  defp json_value(_key, {:string, value}), do: value
  defp json_value(_key, {type, value}) when type in [:byte, :short, :int, :long], do: value
  defp json_value(_key, {:list, _} = list), do: Enum.map(NBT.items(list), &json_value("", &1))
  defp json_value(_key, {:float, <<value::float-32>>}), do: value
  defp json_value(_key, {:double, <<value::float-64>>}), do: value
  defp json_value(_key, {:int_array, bytes}), do: for(<<value::signed-32 <- bytes>>, do: value)
end
