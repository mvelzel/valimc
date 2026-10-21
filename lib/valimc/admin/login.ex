defmodule Valimc.Admin.Login do
  @moduledoc """
  Vanilla's `PlayerList.canPlayerLogin` checks (VMC-010a), read from the
  published admin lists in the connection process: a banned profile, the
  whitelist, a banned IP, then (in `Valimc.Players.join/2`) a full server that
  only operators with `bypassesPlayerLimit` may still join.
  """
  alias Valimc.Admin.Lists
  alias Valimc.Text

  @doc "The disconnect reason for a profile joining from `ip`, or nil."
  def refusal(%{uuid: uuid} = player, ip) do
    cond do
      ban = Lists.ban(uuid) ->
        banned(
          "multiplayer.disconnect.banned.reason",
          "multiplayer.disconnect.banned.expiration",
          ban
        )

      Valimc.World.Settings.get(:white_list) and not Valimc.Permissions.operator?(player) and
          not Lists.whitelisted?(uuid) ->
        Text.translatable("multiplayer.disconnect.not_whitelisted")

      ban = ip && Lists.ip_ban(ip) ->
        banned(
          "multiplayer.disconnect.banned_ip.reason",
          "multiplayer.disconnect.banned_ip.expiration",
          ban
        )

      true ->
        nil
    end
  end

  @doc "Whether the player may join a full server."
  def bypasses_limit?(%{uuid: uuid}), do: match?({_, true}, Lists.op(uuid))

  @doc "The ban reason shown to players: the entry's reason or vanilla's default."
  def reason(%{"reason" => reason}) when is_binary(reason), do: Text.literal(reason)
  def reason(_), do: Text.translatable("multiplayer.disconnect.banned.reason.default")

  defp banned(key, expiration, ban) do
    message = Text.translatable(key, [reason(ban)])

    case ban["expires"] do
      "forever" ->
        message

      text ->
        {:ok, at} = Valimc.Admin.ListFile.parse_date(text)
        Text.append(message, Text.translatable(expiration, [expiry(at)]))
    end
  end

  # `yyyy-MM-dd 'at' HH:mm:ss z`; the zone is written as its offset from GMT.
  defp expiry(unix) do
    [date, time, offset] = String.split(Valimc.Admin.ListFile.format(unix), " ")
    <<sign, hours::binary-size(2), minutes::binary-size(2)>> = offset
    "#{date} at #{time} GMT#{<<sign>>}#{hours}:#{minutes}"
  end

  @doc "The peer's IPv4 address as vanilla prints it; IPv6 peers never match an IP ban."
  def address(socket) when is_port(socket) do
    case :inet.peername(socket) do
      {:ok, {{a, b, c, d}, _port}} -> "#{a}.#{b}.#{c}.#{d}"
      _ -> nil
    end
  end

  def address(_socket), do: nil
end
