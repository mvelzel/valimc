defmodule Valimc.Commands.Parser.Dispatcher do
  @moduledoc """
  Brigadier's parse (VMC-053): `CommandDispatcher.parseNodes` with the same node
  relevance, separator, redirect and potential-ranking rules, and vanilla's
  `Commands.finishParsing` checks, over `Valimc.Commands.Parser.Tree` nodes.

  Parsing is a pure function of the input, the tree and the command source.
  """
  alias Valimc.Commands.Parser.Arguments
  alias Valimc.Text.{Error, Reader}

  defmodule Context do
    @moduledoc false
    defstruct [:root, :start, :end, nodes: [], arguments: %{}, command: nil, child: nil]
  end

  defmodule Parse do
    @moduledoc false
    defstruct [:context, :reader, errors: []]
  end

  @doc "Parses `command` (without `/`) for `source` against the `root` node."
  def parse(root, command, source) do
    reader = Reader.new(command)
    parse_nodes(root, reader, %Context{root: root.path, start: 0, end: 0}, source)
  end

  defp parse_nodes(node, original, so_far, source) do
    cursor = original.cursor

    node
    |> relevant_nodes(original)
    |> Enum.reduce_while({[], []}, fn child, {potentials, errors} ->
      if usable?(child, source) do
        case parse_child(child, original, so_far, source) do
          {:ok, reader, context} ->
            context = %{context | command: child.command}

            cond do
              Reader.can_read?(reader, if(child.redirect, do: 1, else: 2)) and
                  child.redirect != nil ->
                reader = Reader.skip(reader)
                target = Valimc.Commands.node!(child.redirect)

                child_context = %Context{
                  root: target.path,
                  start: reader.cursor,
                  end: reader.cursor
                }

                parse = parse_nodes(target, reader, child_context, source)

                {:halt,
                 {:redirect,
                  %Parse{
                    context: %{context | child: parse.context},
                    reader: parse.reader,
                    errors: parse.errors
                  }}}

              Reader.can_read?(reader, 2) ->
                parse = parse_nodes(child, Reader.skip(reader), context, source)
                {:cont, {potentials ++ [parse], errors}}

              true ->
                {:cont, {potentials ++ [%Parse{context: context, reader: reader}], errors}}
            end

          {:error, error} ->
            {:cont, {potentials, errors ++ [{child.path, error}]}}
        end
      else
        {:cont, {potentials, errors}}
      end
    end)
    |> case do
      {:redirect, parse} ->
        parse

      {[], errors} ->
        %Parse{context: so_far, reader: %{original | cursor: cursor}, errors: errors}

      {potentials, _} ->
        potentials
        |> Enum.sort_by(&{Reader.can_read?(&1.reader), &1.errors != []})
        |> hd()
    end
  end

  def usable?(node, source), do: node.level <= source.level

  # Brigadier's `getRelevantNodes`: the literal named by the next word, else the arguments.
  defp relevant_nodes(node, reader) do
    {literals, arguments} = Enum.split_with(node.children, &(&1.type == :literal))

    if literals == [] do
      arguments
    else
      {text, _} = Reader.take_while(reader, &(&1 != ?\s))

      case Enum.find(literals, &(&1.name == text)) do
        nil -> arguments
        literal -> [literal]
      end
    end
  end

  defp parse_child(child, reader, context, source) do
    start = reader.cursor

    result =
      Error.catching(fn ->
        {reader, value} =
          case child.type do
            :literal -> {literal(child.name, reader), nil}
            :argument -> argument(child, reader, source)
          end

        if Reader.can_read?(reader) and Reader.peek(reader) != ?\s,
          do: Error.fail_at!("command.expected.separator", [], reader)

        {reader, value}
      end)

    case result do
      {:ok, {reader, value}} ->
        range = {start, reader.cursor}

        arguments =
          if child.type == :argument,
            do: Map.put(context.arguments, child.name, {value, range}),
            else: context.arguments

        {:ok, reader,
         %{
           context
           | nodes: context.nodes ++ [{child, range}],
             arguments: arguments,
             start: min(context.start, start),
             end: max(context.end, reader.cursor)
         }}

      {:error, error} ->
        {:error, error}
    end
  end

  defp literal(name, reader) do
    expected = Reader.new(name)
    size = expected.size

    matches =
      Reader.can_read?(reader, size) and
        Enum.all?(0..(size - 1)//1, &(Reader.peek(reader, &1) == Reader.peek(expected, &1)))

    after_literal = Reader.set_cursor(reader, reader.cursor + size)

    if matches and (not Reader.can_read?(after_literal) or Reader.peek(after_literal) == ?\s),
      do: after_literal,
      else: Error.fail_at!("argument.literal.incorrect", [name], reader)
  end

  defp argument(node, reader, source) do
    {value, reader} = Arguments.parse(node, reader, source)
    {reader, value}
  end

  @doc """
  Vanilla's `finishParsing`: `{:ok, context}` for the final executable context,
  or `{:error, error}` with vanilla's message and context.
  """
  def finish(%Parse{} = parse) do
    with :ok <- parse_exception(parse) do
      last = last_context(parse.context)

      if last.command,
        do: {:ok, last, parse.context},
        else: {:error, Error.with_context("command.unknown.command", [], parse.reader)}
    end
  end

  defp parse_exception(%Parse{reader: reader, errors: errors, context: context}) do
    cond do
      not Reader.can_read?(reader) ->
        :ok

      length(errors) == 1 ->
        {:error, elem(hd(errors), 1)}

      context.start == context.end ->
        {:error, Error.with_context("command.unknown.command", [], reader)}

      true ->
        {:error, Error.with_context("command.unknown.argument", [], reader)}
    end
  end

  def last_context(%Context{child: nil} = context), do: context
  def last_context(%Context{child: child}), do: last_context(child)

  @doc "Node names per context, as the parse oracle reports them."
  def path(%Context{} = context) do
    names = Enum.map_join(context.nodes, " ", fn {node, _} -> node.name end)
    if context.child, do: [names | path(context.child)], else: [names]
  end
end
