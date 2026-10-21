defmodule Valimc.Command.Feedback do
  @moduledoc """
  Command feedback (VMC-053), vanilla's `CommandSourceStack.sendSuccess`,
  `sendFailure` and `broadcastToAdmins`: the source sees the message; with
  broadcast, other online operators see `[Name: message]` in gray italics.
  A player sees messages through its connection's mailbox, in the order the
  command sent them (commands run beside the connection, VMC-077a).
  """
  require Logger
  alias Valimc.Command.{Error, Source, Text}

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
  defp show(%Source{kind: :console}, component),
    do: Logger.info(Valimc.Command.Render.string(component))

  # RCON collects the text for its reply (`RconConsoleSource` appends each
  # message's string, without separators).
  defp show(%Source{kind: :rcon}, component) do
    Process.put(:valimc_rcon_output, [
      Process.get(:valimc_rcon_output, []),
      Valimc.Command.Render.string(component)
    ])
  end

  defp show(%Source{player: player}, component), do: tell(player, component)

  @doc "A system message to an online player."
  def tell(%{pid: pid}, component) do
    Valimc.Connection.deliver(pid, {:chat, Text.encode(component)})
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
  # `shouldInformAdmins`: RCON's `broadcast-rcon-to-ops`, else the game rule.
  defp inform_admins?(%Source{kind: :rcon}), do: Valimc.config(:broadcast_rcon_to_ops) != false
  defp inform_admins?(_source), do: Valimc.Command.GameRules.get(:send_command_feedback)

  defp admins(source, component) do
    message =
      Text.translatable("chat.type.admin", [Source.display_name(source), component])
      |> Text.style([{"color", "gray"}, {"italic", true}])

    unless Source.console?(source), do: Logger.info(Valimc.Command.Render.string(message))

    if inform_admins?(source) do
      for player <- Valimc.Players.all(),
          source.player == nil or player.pid != source.player.pid,
          Valimc.Permissions.operator?(player),
          do: Valimc.Connection.deliver(player.pid, {:chat, Text.encode(message)})
    end
  end
end
