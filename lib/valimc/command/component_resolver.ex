defmodule Valimc.Command.ComponentResolver do
  @moduledoc """
  `ComponentUtils.updateForEntity` for command text (VMC-053i): selectors become
  the display names they match (for the command source, `@s` being the source),
  scores are empty because ValiMC has no scoreboards yet, translation arguments
  and `show_text` hovers resolve recursively, and the component's own style wins
  over the resolved contents' style. NBT text needs entity and block data and is
  refused.
  """
  alias Valimc.Command.{Error, Source, Text}

  @style ~w(color shadow_color bold italic underlined strikethrough obfuscated click_event hover_event insertion font)
  @depth 100

  def resolve(component, source), do: resolve(component, source, 0)

  defp resolve(component, _source, depth) when depth > @depth, do: component

  defp resolve({:compound, fields} = component, source, depth) do
    {:compound, contents} = contents(component, source, depth + 1)

    siblings =
      case fields["extra"] do
        nil -> []
        list -> Enum.map(tags(list), &resolve(&1, source, depth + 1))
      end

    style =
      fields
      |> Map.take(@style)
      |> then(fn style ->
        case style["hover_event"] do
          {:compound, %{"action" => {:string, "show_text"}, "value" => value} = hover} ->
            Map.put(
              style,
              "hover_event",
              {:compound, Map.put(hover, "value", resolve(value, source, depth + 1))}
            )

          _ ->
            style
        end
      end)

    own_extra =
      case contents["extra"] do
        nil -> []
        list -> tags(list)
      end

    merged = Map.merge(Map.delete(contents, "extra"), style)

    case own_extra ++ siblings do
      [] -> {:compound, merged}
      extra -> {:compound, Map.put(merged, "extra", Valimc.NBT.list(extra))}
    end
  end

  defp contents({:compound, %{"selector" => {:string, text}} = fields}, source, depth) do
    {selector, _} =
      Valimc.Command.Selector.parse(Valimc.Command.Reader.new(text), source.level >= 2)

    names = Enum.map(Source.players(source, selector), &Source.display_name/1)

    separator =
      case fields["separator"] do
        nil -> Text.literal(", ") |> Text.color("gray")
        separator -> resolve(separator, source, depth)
      end

    case names do
      [] ->
        Text.literal("")

      [one] ->
        one

      [first | rest] ->
        Enum.reduce(
          rest,
          Text.empty() |> Text.append(first),
          &(&2 |> Text.append(separator) |> Text.append(&1))
        )
    end
  end

  defp contents({:compound, %{"score" => _}}, _source, _depth), do: Text.literal("")

  defp contents({:compound, %{"nbt" => _}}, _source, _depth),
    do: Error.refuse!("NBT text components are not supported yet")

  defp contents({:compound, %{"translate" => key} = fields}, source, depth) do
    base = %{"translate" => key}
    base = if fields["fallback"], do: Map.put(base, "fallback", fields["fallback"]), else: base

    case fields["with"] do
      nil ->
        {:compound, base}

      args ->
        resolved =
          Enum.map(tags(args), fn
            {:compound, _} = component -> resolve(component, source, depth)
            primitive -> primitive
          end)

        {:compound, Map.put(base, "with", Valimc.NBT.list(resolved))}
    end
  end

  defp contents({:compound, fields}, _source, _depth),
    do: {:compound, Map.drop(fields, ["extra" | @style])}

  defp tags({:list, {:compound, values}}),
    do:
      Enum.map(values, fn
        %{"" => tag} = f when map_size(f) == 1 -> tag
        f -> {:compound, f}
      end)

  defp tags({:list, {type, values}}), do: Enum.map(values, &{type, &1})
end
