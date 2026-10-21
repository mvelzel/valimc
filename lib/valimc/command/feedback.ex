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

  @doc "A message from the server console: logged and shown to operators as `[Server: ...]`."
  def console(component) do
    require Logger
    Logger.info("[Server] " <> log_text(component))

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

  # A readable log line: literal text, or a translation key with its arguments.
  defp log_text({:compound, %{"translate" => {:string, key}} = fields}) do
    case fields["with"] do
      nil -> key
      args -> key <> " " <> inspect(Enum.map(Text.list_items(args), &log_arg/1))
    end
  end

  defp log_text(component), do: Text.plain(component)

  defp log_arg({:compound, _} = component), do: log_text(component)
  defp log_arg({_type, value}), do: value

  defp admins(source, component) do
    if Valimc.Command.GameRules.get(:send_command_feedback) do
      message =
        Text.translatable("chat.type.admin", [Source.display_name(source), component])
        |> Text.style([{"color", "gray"}, {"italic", true}])

      for player <- Valimc.Players.all(),
          player.pid != self(),
          Valimc.Permissions.operator?(player),
          do: Valimc.Connection.deliver(player.pid, {:chat, Text.encode(message)})
    end
  end
end
