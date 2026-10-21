defmodule Valimc.ServerConnectionTest do
  use ExUnit.Case, async: false
  # Save control and the idle kick over sockets (VMC-010b, VMC-010c).
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.Wire

  defp name(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp command(client, input, key) do
    Client.send_packet(client, :play, "chat_command", Wire.string(input))
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, key) != :nomatch, "#{input}: #{inspect(body)}"
    client
  end

  defp join do
    player = name("Save")
    {_, client} = Client.login(player)
    on_exit(fn -> Client.close(client) end)
    {Client.load_world(client), Enum.find(Valimc.Players.all(), &(&1.name == player)).pid}
  end

  test "save-off, save-on and save-all" do
    on_exit(fn -> Valimc.World.Saving.set_auto(true) end)
    {client, _pid} = join()
    client = command(client, "save-off", "commands.save.disabled")
    refute Valimc.World.Saving.auto?()
    client = command(client, "save-off", "commands.save.alreadyOff")
    client = command(client, "save-on", "commands.save.enabled")
    client = command(client, "save-all", "commands.save.saving")
    {body, client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "commands.save.success") != :nomatch
    client = command(client, "save-all flush", "commands.save.saving")
    {body, _client} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "commands.save.success") != :nomatch
  end

  test "an idle player is disconnected after the idle timeout" do
    on_exit(fn -> Valimc.World.Settings.put(idle_timeout: 0) end)
    {client, pid} = join()
    client = command(client, "setidletimeout 5", "commands.setidletimeout.success")
    assert Valimc.World.Settings.get(:idle_timeout) == 5
    :sys.replace_state(pid, &%{&1 | last_action: &1.last_action - 6 * 60_000})
    send(pid, :keepalive)
    {body, _client} = Client.await(client, :play, "disconnect")
    assert :binary.match(body, "multiplayer.disconnect.idling") != :nomatch
  end
end
