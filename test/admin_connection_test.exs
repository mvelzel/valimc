defmodule Valimc.AdminConnectionTest do
  use ExUnit.Case, async: false
  # Operator, ban and whitelist commands and login checks over sockets (VMC-010a, VMC-053f2).
  @moduletag :tcp
  alias Valimc.Admin.Lists
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.Wire

  defp name(prefix),
    do: String.downcase(prefix) <> Integer.to_string(System.unique_integer([:positive]))

  defp command(client, input, key) do
    Client.send_packet(client, :play, "chat_command", Wire.string(input))
    feedback(client, input, key, 20)
  end

  # Multi-line feedback (`banlist`) may still be arriving from the command before.
  defp feedback(client, input, key, lines) do
    {body, client} = Client.await(client, :play, "system_chat")

    cond do
      :binary.match(body, key) != :nomatch -> client
      lines > 0 -> feedback(client, input, key, lines - 1)
      true -> flunk("#{input}: #{inspect(body)}")
    end
  end

  defp join(player) do
    {_, client} = Client.login(player)
    on_exit(fn -> Client.close(client) end)
    Client.load_world(client)
  end

  defp refused(player) do
    {body, client} = Client.await(Client.begin_login(player), :login, "login_disconnect")
    Client.close(client)
    body
  end

  defp profile(player), do: %{uuid: Valimc.Connection.offline_uuid(player), name: player}

  # Leaves the shared lists as other suites expect them.
  defp restore(operators) do
    Application.put_env(:valimc, :operators, operators)
    Lists.set_white_list(false)
  end

  test "a banned profile cannot join until pardoned" do
    admin = join(name("Admin"))
    banned = name("banned")

    admin = command(admin, "ban #{banned} griefing", "commands.ban.success")
    body = refused(banned)
    assert :binary.match(body, "multiplayer.disconnect.banned.reason") != :nomatch
    assert :binary.match(body, "griefing") != :nomatch

    admin = command(admin, "ban #{banned}", "commands.ban.failed")
    admin = command(admin, "banlist players", "commands.banlist.list")
    admin = command(admin, "pardon #{banned}", "commands.pardon.success")
    _ = command(admin, "pardon #{banned}", "commands.pardon.failed")
    _ = join(banned)
  end

  test "IP bans, banlist and transfer" do
    admin = join(name("Ips"))
    admin = command(admin, "ban-ip 10.1.2.3 spam", "commands.banip.success")
    admin = command(admin, "ban-ip 10.1.2.3", "commands.banip.failed")
    admin = command(admin, "ban-ip nobody", "commands.banip.invalid")
    admin = command(admin, "banlist ips", "commands.banlist.list")
    admin = command(admin, "pardon-ip 10.1.2.3", "commands.pardonip.success")
    admin = command(admin, "pardon-ip 10.1.2.3", "commands.pardonip.failed")

    Client.send_packet(admin, :play, "chat_command", Wire.string("transfer example.com 25566"))
    {body, admin} = Client.await(admin, :play, "transfer")
    assert body == IO.iodata_to_binary([Wire.string("example.com"), Wire.varint(25566)])
    _ = Client.await(admin, :play, "system_chat")
  end

  test "op and deop change a player's level; the whitelist admits operators and listed players" do
    previous = Application.get_env(:valimc, :operators)
    on_exit(fn -> restore(previous) end)
    Application.put_env(:valimc, :operators, [])

    owner = name("Owner")
    [_] = Lists.add_ops([profile(owner)], 4)
    on_exit(fn -> Lists.remove_ops([profile(owner)]) end)
    admin = join(owner)

    guest = name("guest")
    guest_client = join(guest)
    admin = command(admin, "op #{guest}", "commands.op.success")
    {event, guest_client} = Client.await(guest_client, :play, "entity_event")
    assert binary_part(event, byte_size(event), -1) == <<28>>
    {_, guest_client} = Client.await(guest_client, :play, "commands")
    admin = command(admin, "op #{guest}", "commands.op.failed")
    admin = command(admin, "deop #{guest}", "commands.deop.success")
    {event, _} = Client.await(guest_client, :play, "entity_event")
    assert binary_part(event, byte_size(event), -1) == <<24>>

    outsider = name("outsider")
    admin = command(admin, "whitelist on", "commands.whitelist.enabled")
    assert :binary.match(refused(outsider), "multiplayer.disconnect.not_whitelisted") != :nomatch
    admin = command(admin, "whitelist add #{outsider}", "commands.whitelist.add.success")
    _ = join(outsider)
    admin = command(admin, "whitelist list", "commands.whitelist.list")
    admin = command(admin, "whitelist remove #{outsider}", "commands.whitelist.remove.success")
    _ = command(admin, "whitelist off", "commands.whitelist.disabled")
  end

  test "a second login of the same profile replaces the first" do
    player = name("twice")
    {_, first} = Client.login(player)
    first = Client.load_world(first)
    {_, second} = Client.login(player)
    on_exit(fn -> Client.close(second) end)
    {body, _} = Client.await(first, :play, "disconnect")
    assert :binary.match(body, "multiplayer.disconnect.duplicate_login") != :nomatch
    _ = command(Client.load_world(second), "list", "commands.list.players")
  end
end
