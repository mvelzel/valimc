defmodule Valimc.Commands.Chat do
  @moduledoc "Chat and information commands (VMC-053): `/help`."
  alias Valimc.Command.{Dispatcher, Error, Feedback, Text}

  @doc "`/help`: vanilla's smart usage of every command the source may use."
  def help(_arguments, source) do
    usage = smart_usage(Valimc.Commands.root(), source)
    for line <- usage, do: Feedback.success(source, Text.literal("/" <> line), false)
    {length(usage), source.state}
  end

  @doc "`/help <command>`: the smart usage below the deepest node the text parses to."
  def help_command(%{"command" => command}, source) do
    parse = Dispatcher.parse(Valimc.Commands.root(), command, source)

    case parse.context.nodes do
      [] ->
        Error.fail!("commands.help.failed")

      nodes ->
        {node, _} = List.last(nodes)
        usage = smart_usage(node, source)

        for line <- usage,
            do: Feedback.success(source, Text.literal("/#{command} #{line}"), false)

        {length(usage), source.state}
    end
  end

  # Brigadier's `getSmartUsage`.
  defp smart_usage(node, source) do
    optional = node.command != nil

    for child <- node.children,
        line = usage(child, source, optional, false),
        line != nil,
        do: line
  end

  defp usage(node, source, optional, deep) do
    if Dispatcher.usable?(node, source) do
      self = if optional, do: "[#{text(node)}]", else: text(node)
      child_optional = node.command != nil
      {open, close} = if child_optional, do: {"[", "]"}, else: {"(", ")"}

      cond do
        deep ->
          self

        node.redirect != nil ->
          target = if node.redirect == [], do: "...", else: "-> " <> List.last(node.redirect)
          self <> " " <> target

        true ->
          children = Enum.filter(node.children, &Dispatcher.usable?(&1, source))

          case children do
            [] ->
              self

            [child] ->
              case usage(child, source, child_optional, child_optional) do
                nil -> self
                line -> self <> " " <> line
              end

            _ ->
              lines =
                children
                |> Enum.map(&usage(&1, source, child_optional, true))
                |> Enum.reject(&is_nil/1)
                |> Enum.uniq()

              case lines do
                [line] -> self <> " " <> if(child_optional, do: "[#{line}]", else: line)
                [] -> self
                _ -> self <> " " <> open <> Enum.map_join(children, "|", &text/1) <> close
              end
          end
      end
    end
  end

  defp text(%{type: :argument, name: name}), do: "<#{name}>"
  defp text(%{name: name}), do: name
end
