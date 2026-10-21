defmodule Valimc.Command.Feedback do
  @moduledoc """
  Command feedback (VMC-053), vanilla's `CommandSourceStack.sendSuccess`,
  `sendFailure` and `broadcastToAdmins`: the source sees the message; with
  broadcast, other online operators see `[Name: message]` in gray italics.
  """
  require Logger
  alias Valimc.Command.{Error, Source, Text}
  alias Valimc.Protocol.Packets
  import Valimc.Net.Codec, only: [send_packets: 2]

  def success(%Source{} = source, component, broadcast \\ true) do
    show(source, component)
    if broadcast, do: admins(source, component)
    :ok
  end

  def failure(%Source{} = source, component) do
    show(source, Error.failure(component))
    :ok
  end

  # The console prints the English text (`sendSystemMessage` logs `getString`).
  defp show(%Source{state: nil, player: nil}, component),
    do: Logger.info(Valimc.Command.Render.string(component))

  defp show(source, component),
    do: send_packets(source.state, [Packets.chat(Text.encode(component))])

  @doc "A system message to another online player (or to the source itself)."
  def tell(%Source{} = source, %{pid: pid}, component) do
    if pid == self() and source.state != nil,
      do: send_packets(source.state, [Packets.chat(Text.encode(component))]),
      else: Valimc.Connection.deliver(pid, {:chat, Text.encode(component)})

    :ok
  end

  @doc "A message from the server console: logged and shown to operators as `[Server: ...]`."
  def console(component) do
    Logger.info("[Server] " <> Valimc.Command.Render.string(component))

    if Valimc.Command.GameRules.get(:send_command_feedback) do
      message =
        Text.translatable("chat.type.admin", [Text.literal("Server"), component])
        |> Text.style([{"color", "gray"}, {"italic", true}])

      for player <- Valimc.Players.all(),
          Valimc.Permissions.operator?(player),
          do: Valimc.Connection.deliver(player.pid, {:chat, Text.encode(message)})
    end

    :ok
  end

  # `broadcastToAdmins`: other operators see `[Name: message]`, and a player's
  # broadcast is also logged to the console (`logAdminCommands`).
  defp admins(source, component) do
    message =
      Text.translatable("chat.type.admin", [Source.display_name(source), component])
      |> Text.style([{"color", "gray"}, {"italic", true}])

    unless Source.console?(source), do: Logger.info(Valimc.Command.Render.string(message))

    if Valimc.Command.GameRules.get(:send_command_feedback) do
      for player <- Valimc.Players.all(),
          player.pid != self(),
          Valimc.Permissions.operator?(player),
          do: Valimc.Connection.deliver(player.pid, {:chat, Text.encode(message)})
    end
  end
end
