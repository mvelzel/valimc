defmodule Valimc.Command.Text do
  @moduledoc """
  Server-authored text components for command feedback (VMC-053), as network NBT.

  Builders mirror vanilla's `Component` constructors so the client decodes the
  same component structure vanilla sends: `literal/1`, `translatable/2`
  (`translatableEscape`: strings and numbers stay primitive arguments), `empty/0`,
  `append/2` (siblings) and `style/2`.
  """
  alias Valimc.NBT

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
        {:list, {_, _}} = list -> list_tags(list) ++ [child]
      end

    {:compound, Map.put(fields, "extra", NBT.list(extra))}
  end

  defp list_tags({:list, {:compound, values}}),
    do:
      Enum.map(values, fn
        %{"" => tag} = fields when map_size(fields) == 1 -> tag
        fields -> {:compound, fields}
      end)

  defp list_tags({:list, {type, values}}), do: Enum.map(values, &{type, &1})

  @doc "Merges style fields (`color`, `bold`, `click_event`, ...) where unset, like `withStyle`."
  def style({:compound, fields}, styles) do
    {:compound,
     Enum.reduce(styles, fields, fn {key, value}, acc -> Map.put(acc, key, style_value(value)) end)}
  end

  defp style_value(value) when is_binary(value), do: {:string, value}
  defp style_value(value) when is_boolean(value), do: {:byte, if(value, do: 1, else: 0)}
  defp style_value({_, _} = tag), do: tag

  def color(component, color), do: style(component, [{"color", color}])

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
end
