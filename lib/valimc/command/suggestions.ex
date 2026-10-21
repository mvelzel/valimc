defmodule Valimc.Command.Suggestions do
  @moduledoc """
  Server command suggestions (VMC-053e), answering the client's
  `command_suggestion` request for `ask_server` nodes. As vanilla's
  `ServerCommandSuggestionsProvider` and Brigadier's `getCompletionSuggestions`:
  parse the text, find the node before the cursor, ask each child and merge.

  Literals answer here, and `ask_server` nodes ask the provider their command
  registers (VMC-077o); other argument types suggest in the client, which
  merges them with this reply.
  """
  alias Valimc.Command.{Dispatcher, Reader}

  @max 1000

  @doc "`{start, length, [text]}` for the request text (with or without its `/`)."
  def suggest(text, source) do
    offset = if String.starts_with?(text, "/"), do: 1, else: 0
    command = binary_part(text, offset, byte_size(text) - offset)
    reader = Reader.new(command)
    cursor = reader.size
    parse = Dispatcher.parse(Valimc.Commands.root(), command, source)
    {parent, start, context} = find(parse.context, cursor, Valimc.Commands.root())
    context = Map.put(context, :source, source)
    start = min(start, cursor)
    remaining = Reader.slice(reader, start, cursor)

    texts =
      parent.children
      |> Enum.flat_map(&child(&1, remaining, context))
      |> Enum.uniq()
      |> Enum.sort_by(&String.downcase/1)
      |> Enum.take(@max)

    if texts == [], do: {offset, 0, []}, else: {start + offset, cursor - start, texts}
  end

  # Brigadier's `CommandContextBuilder.findSuggestionContext`.
  defp find(context, cursor, root) do
    node_at = fn path -> if path == [], do: root, else: Valimc.Commands.node!(path) end

    cond do
      context.end < cursor and context.child != nil ->
        find(context.child, cursor, root)

      context.end < cursor and context.nodes != [] ->
        {node, {_, last_end}} = List.last(context.nodes)
        {node, last_end + 1, context}

      context.end < cursor ->
        {node_at.(context.root), context.start, context}

      true ->
        Enum.reduce_while(context.nodes, {node_at.(context.root), context.start, context}, fn
          {node, {from, to}}, {previous, _, _} ->
            if from <= cursor and cursor <= to,
              do: {:halt, {previous, from, context}},
              else: {:cont, {node, context.start, context}}
        end)
    end
  end

  defp child(%{type: :literal, name: name}, remaining, _context) do
    if String.starts_with?(String.downcase(name), String.downcase(remaining)),
      do: [name],
      else: []
  end

  # `ask_server` nodes: the command's own provider (`suggest/3` of its handler
  # module, registered with `suggest: true` in `Valimc.Commands.registry/0`).
  defp child(%{suggestions: "minecraft:ask_server", path: [name | _] = path}, remaining, context) do
    arguments = Map.new(context.arguments, fn {key, {value, _range}} -> {key, value} end)
    contents = String.downcase(remaining)

    case Valimc.Commands.suggester(name) do
      nil ->
        []

      module ->
        case module.suggest(path, arguments, context.source) do
          {:names, names} -> Enum.filter(names, &matches_sub_str?(contents, String.downcase(&1)))
          {:resources, ids} -> resources(ids, contents)
        end
    end
  end

  defp child(_node, _remaining, _context), do: []

  # `SharedSuggestionProvider.filterResources` with `matchesSubStr`.
  defp resources(ids, contents) do
    namespaced = String.contains?(contents, ":")

    Enum.filter(ids, fn id ->
      [namespace, path] = String.split(id, ":", parts: 2)

      if namespaced,
        do: matches_sub_str?(contents, id),
        else: matches_sub_str?(contents, namespace) or matches_sub_str?(contents, path)
    end)
  end

  @doc "Vanilla `matchesSubStr`: `pattern` starts the input or a part after `.`, `_` or `/`."
  def matches_sub_str?(pattern, input), do: match_from(pattern, input, 0)

  defp match_from(pattern, input, index) do
    rest = binary_part(input, index, byte_size(input) - index)

    cond do
      String.starts_with?(rest, pattern) ->
        true

      true ->
        case :binary.match(rest, [".", "_", "/"]) do
          {at, 1} -> match_from(pattern, input, index + at + 1)
          :nomatch -> false
        end
    end
  end

  @doc "The `command_suggestions` packet."
  def packet(id, {start, length, texts}) do
    alias Valimc.Protocol.{Packets, Wire}

    Packets.packet("command_suggestions", [
      Wire.varint(id),
      Wire.varint(start),
      Wire.varint(length),
      Wire.varint(length(texts)),
      Enum.map(texts, &[Wire.string(&1), <<0>>])
    ])
  end
end
