defmodule Valimc.Session.Presence do
  @moduledoc """
  Joining and leaving (VMC-010f): vanilla's server log lines and the yellow
  "joined the game" and "left the game" messages every player sees.

  `PlayerList.placeNewPlayer` logs `Name[/address:port] logged in with entity id
  N at (x, y, z)` and broadcasts `multiplayer.player.joined`;
  `ServerGamePacketListenerImpl.onDisconnect` logs `Name lost connection:
  reason` and broadcasts `multiplayer.player.left`. A connection records its
  disconnect reason (`record/1`) where it ends the session; a closed socket is
  vanilla's "End of stream".
  """
  require Logger
  alias Valimc.Command.{Render, Text}
  alias Valimc.Protocol.Packets

  @reason {__MODULE__, :reason}

  def joined(state) do
    player = state.player
    [x, y, z] = Enum.map([player.x, player.y, player.z], &Render.java_float(&1 * 1.0, 64))

    Logger.info(
      "#{player.name}[#{address(state.socket)}] logged in with entity id #{player.entity_id} at (#{x}, #{y}, #{z})"
    )

    message =
      Text.translatable("multiplayer.player.joined", [name(player)]) |> Text.color("yellow")

    Logger.info(Render.string(message))
    packet = Packets.chat(Text.encode(message))
    Valimc.Net.Codec.send_packets(state, [packet])
    Valimc.Players.broadcast({:packet, packet}, self())
    state
  end

  @doc "Remembers why this connection ends (a text or a server text component)."
  def record(reason), do: Process.put(@reason, reason)

  def left(%{phase: :play, player: %{name: _} = player}, exit_reason) do
    reason =
      case {Process.get(@reason), exit_reason} do
        {nil, :shutdown} -> Text.translatable("multiplayer.disconnect.server_shutdown")
        {nil, {:shutdown, _}} -> Text.translatable("multiplayer.disconnect.server_shutdown")
        {nil, _} -> Text.translatable("disconnect.endOfStream")
        {%Valimc.Protocol.ServerText{tag: tag}, _} -> tag
        {text, _} when is_binary(text) -> Text.literal(text)
        {_, _} -> Text.translatable("disconnect.endOfStream")
      end

    Logger.info("#{player.name} lost connection: #{Render.string(reason)}")
    message = Text.translatable("multiplayer.player.left", [name(player)]) |> Text.color("yellow")
    Logger.info(Render.string(message))
    Valimc.Players.broadcast({:packet, Packets.chat(Text.encode(message))}, self())
  end

  def left(_state, _exit_reason), do: :ok

  defp name(player), do: Text.player_name(player.name, player.uuid)

  defp address(socket) when is_port(socket) do
    case :inet.peername(socket) do
      {:ok, {{a, b, c, d}, port}} -> "/#{a}.#{b}.#{c}.#{d}:#{port}"
      _ -> "local"
    end
  end

  defp address(_socket), do: "local"
end
