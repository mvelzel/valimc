defmodule Valimc.Commands.Feedback do
  @moduledoc """
  Command feedback (VMC-053, VMC-077o), vanilla's `CommandSourceStack.sendSuccess`,
  `sendFailure` and `broadcastToAdmins`: the source's sink renders the message
  (a player's connection, the console log, RCON's collected reply) in the
  order the command sends it; with broadcast, other online operators see
  `[Name: message]` in gray italics. A silent source shows nothing.
  """
  require Logger
  alias Valimc.Text.Error
  alias Valimc.Commands.{Source, Targets}
  alias Valimc.World.GameRules
  alias Valimc.Text
  alias Valimc.Text.Render

  def success(%Source{} = source, component, broadcast \\ true) do
    show(source, component)
    if broadcast, do: admins(source, component)
    :ok
  end

  def failure(%Source{} = source, component) do
    show(source, Error.failure(component))
    :ok
  end

  @doc """
  Vanilla's single/multiple feedback over `targets`: `key.single` with
  `args ++ [name]` for one target, `key.multiple` with `args ++ [count]` for
  more, nothing for none.
  """
  def targets(source, targets, key, args \\ [], broadcast \\ true)
  def targets(_source, [], _key, _args, _broadcast), do: :ok

  def targets(source, [one], key, args, broadcast),
    do:
      success(
        source,
        Text.translatable(key <> ".single", args ++ [Source.display_name(one)]),
        broadcast
      )

  def targets(source, many, key, args, broadcast),
    do: success(source, Text.translatable(key <> ".multiple", args ++ [length(many)]), broadcast)

  defp show(%Source{silent: true}, _component), do: :ok

  # The console prints the English text (`sendSystemMessage` logs `getString`).
  defp show(%Source{sink: :log}, component), do: Logger.info(Render.string(component))

  defp show(%Source{kind: :console, sink: {:collect, pid, ref}}, component),
    do: send(pid, {ref, Render.string(component) <> "\n"})

  # RCON collects the text for its reply (`RconConsoleSource` appends each
  # message's string, without separators).
  defp show(%Source{sink: {:collect, pid, ref}}, component),
    do: send(pid, {ref, Render.string(component)})

  defp show(%Source{sink: {:player, pid}}, component), do: tell(%{pid: pid}, component)

  @doc "A system message to an online player."
  def tell(%{pid: pid}, component) do
    Valimc.Player.PlayerList.deliver(pid, {:chat, Text.encode(component)})
    :ok
  end

  # `broadcastToAdmins`: other operators see `[Name: message]`, and a player's
  # broadcast is also logged to the console (`logAdminCommands`).
  # `shouldInformAdmins`: RCON's `broadcast-rcon-to-ops`, else the game rule.
  defp inform_admins?(%Source{kind: :rcon}), do: Valimc.config(:broadcast_rcon_to_ops) != false
  defp inform_admins?(_source), do: GameRules.get(:send_command_feedback)

  defp admins(%Source{silent: true}, _component), do: :ok

  defp admins(source, component) do
    message =
      Text.translatable("chat.type.admin", [Source.display_name(source), component])
      |> Text.style([{"color", "gray"}, {"italic", true}])

    unless Source.console?(source), do: Logger.info(Render.string(message))

    if inform_admins?(source) do
      for player <- Targets.online(source),
          not Source.self?(source, player),
          Valimc.Admin.Permissions.operator?(player),
          do: tell(player, message)
    end
  end
end
