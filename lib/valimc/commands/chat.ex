defmodule Valimc.Commands.Chat do
  @moduledoc """
  Chat and information commands (VMC-053d): `help`, `say`, `me`, `msg`/`tell`/`w`
  and `list`. Command chat is unsigned, so vanilla sends it as disguised chat
  bound to the command's chat type and the sender's display name.
  """
  require Logger
  alias Valimc.Command.{Dispatcher, Error, Feedback, Reader, Source}
  alias Valimc.Text
  alias Valimc.Protocol.{Data, Packets, Wire}

  @doc """
  `/help`: vanilla's smart usage of every command the source may use;
  `/help <command>`: below the deepest node the text parses to.
  """
  def help(%{"command" => command}, source), do: help_command(command, source)

  def help(_arguments, source) do
    usage = smart_usage(Valimc.Commands.root(), source)
    for line <- usage, do: Feedback.success(source, Text.literal("/" <> line), false)
    length(usage)
  end

  defp help_command(command, source) do
    parse = Dispatcher.parse(Valimc.Commands.root(), command, source)

    case parse.context.nodes do
      [] ->
        Error.fail!("commands.help.failed")

      nodes ->
        {node, _} = List.last(nodes)
        usage = smart_usage(node, source)

        for line <- usage,
            do: Feedback.success(source, Text.literal("/#{command} #{line}"), false)

        length(usage)
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

  # ---- chat ----

  @doc "`/say <message>`: an announcement to every player."
  def say(%{"message" => message}, source),
    do: broadcast(source, message, "minecraft:say_command")

  @doc "`/me <action>`: an emote to every player."
  def me(%{"action" => message}, source),
    do: broadcast(source, message, "minecraft:emote_command")

  defp broadcast(source, message, chat_type) do
    content = resolve(source, message)
    name = Source.display_name(source)
    packet = disguised(content, chat_type, name, nil)
    Valimc.Players.broadcast({:packet, packet})
    # The server logs the decorated message (`logChatMessage`).
    decoration =
      if chat_type == "minecraft:emote_command",
        do: "chat.type.emote",
        else: "chat.type.announcement"

    Logger.info(Valimc.Text.Render.string(Text.translatable(decoration, [name, content])))
    1
  end

  @doc "`/msg <targets> <message>`: whispers, echoed to the sender."
  def msg(%{"targets" => selector, "message" => message}, source) do
    targets = Source.required_players(source, selector)
    content = resolve(source, message)
    sender = Source.display_name(source)

    for target <- targets do
      outgoing =
        disguised(content, "minecraft:msg_command_outgoing", sender, Source.display_name(target))

      if source.player,
        do: Valimc.Connection.deliver(source.player.pid, {:packet, outgoing}),
        else:
          Logger.info(
            Valimc.Text.Render.string(
              Text.translatable("commands.message.display.outgoing", [
                Source.display_name(target),
                content
              ])
            )
          )

      incoming = disguised(content, "minecraft:msg_command_incoming", sender, nil)

      Valimc.Connection.deliver(target.pid, {:packet, incoming})
    end

    length(targets)
  end

  defp disguised(content, chat_type, name, target) do
    Packets.packet("disguised_chat", [
      Wire.text_component(Text.encode(content)),
      Wire.varint(Data.registry_id("minecraft:chat_type", chat_type) + 1),
      Wire.text_component(Text.encode(name)),
      if(target, do: [<<1>>, Wire.text_component(Text.encode(target))], else: <<0>>)
    ])
  end

  @doc "`MessageArgument.Message.toComponent`: selectors become the names they match."
  def resolve(source, {:message, text, parts}) do
    if parts != [] and source.level >= 2 do
      reader = Reader.new(text)
      [{first, _, _} | _] = parts

      {component, read_to} =
        Enum.reduce(parts, {Text.literal(Reader.slice(reader, 0, first)), first}, fn {from, to,
                                                                                      selector},
                                                                                     {acc,
                                                                                      read_to} ->
          names = join_names(Source.players(source, selector))

          acc =
            if read_to < from,
              do: Text.append(acc, Text.literal(Reader.slice(reader, read_to, from))),
              else: acc

          {Text.append(acc, names), to}
        end)

      if read_to < reader.size,
        do: Text.append(component, Text.literal(Reader.slice(reader, read_to, reader.size))),
        else: component
    else
      Text.literal(text)
    end
  end

  @doc "`EntitySelector.joinNames` (`ComponentUtils.formatList` with a gray \", \")."
  def join_names([]), do: Text.empty()
  def join_names([one]), do: Source.display_name(one)

  def join_names([first | rest]) do
    separator = Text.literal(", ") |> Text.color("gray")

    Enum.reduce(rest, Text.empty() |> Text.append(Source.display_name(first)), fn player, acc ->
      acc |> Text.append(separator) |> Text.append(Source.display_name(player))
    end)
  end

  # ---- list ----

  def list(%{literals: ["uuids"]}, source), do: list_uuids(source)
  def list(_arguments, source), do: list_players(source, &Source.display_name/1)

  defp list_uuids(source) do
    list_players(source, fn player ->
      Text.translatable("commands.list.nameAndId", [
        Text.literal(player.name),
        Text.literal(Valimc.UUID.to_string(player.uuid))
      ])
    end)
  end

  defp list_players(source, format) do
    players = Valimc.Players.all() |> Enum.sort_by(& &1.entity_id)

    names =
      case players do
        [] ->
          Text.empty()

        [one] ->
          format.(one)

        [first | rest] ->
          separator = Text.literal(", ") |> Text.color("gray")

          Enum.reduce(rest, Text.empty() |> Text.append(format.(first)), fn player, acc ->
            acc |> Text.append(separator) |> Text.append(format.(player))
          end)
      end

    message =
      Text.translatable("commands.list.players", [
        length(players),
        Valimc.config(:max_players),
        names
      ])

    Feedback.success(source, message, false)
    length(players)
  end
end
