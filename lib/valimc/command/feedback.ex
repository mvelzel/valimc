defmodule Valimc.Command.Feedback do
  @moduledoc """
  Command feedback (VMC-053), vanilla's `CommandSourceStack.sendSuccess`,
  `sendFailure` and `broadcastToAdmins`: the source sees the message; with
  broadcast, other online operators see `[Name: message]` in gray italics.
  """
  alias Valimc.Command.{Error, Source, Text}
  alias Valimc.Protocol.Packets
  import Valimc.Net.Codec, only: [send_packets: 2]

  def success(%Source{} = source, component, broadcast \\ true) do
    send_packets(source.state, [Packets.chat(Text.encode(component))])
    if broadcast, do: admins(source, component)
    :ok
  end

  def failure(%Source{} = source, component) do
    send_packets(source.state, [Packets.chat(Text.encode(Error.failure(component)))])
    :ok
  end

  @doc "A system message to another online player (or to the source itself)."
  def tell(%Source{} = source, %{pid: pid}, component) do
    if pid == self(),
      do: send_packets(source.state, [Packets.chat(Text.encode(component))]),
      else: Valimc.Connection.deliver(pid, {:chat, Text.encode(component)})

    :ok
  end

  defp admins(source, component) do
    if Valimc.Command.GameRules.get(:send_command_feedback) do
      message =
        Text.translatable("chat.type.admin", [Source.display_name(source), component])
        |> Text.style([{"color", "gray"}, {"italic", true}])

      for player <- Valimc.Players.all(),
          player.pid != self(),
          Valimc.Permissions.operator?(player.name),
          do: Valimc.Connection.deliver(player.pid, {:chat, Text.encode(message)})
    end
  end
end
