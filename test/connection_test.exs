defmodule Valimc.ConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Data, Wire}
  defp name(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  test "fragmented status handshake returns 26.3 metadata and echoes ping" do
    client = Client.connect()
    on_exit(fn -> Client.close(client) end)
    bytes = Wire.frame(0, [Wire.varint(777), Wire.string("localhost"), <<25565::16, 1>>])
    for <<byte <- bytes>>, do: Client.send_raw(client, <<byte>>)
    Client.send_raw(client, Wire.frame(0, <<>>) <> Wire.frame(1, <<42::signed-64>>))
    {0, body, client} = Client.read(client)
    {json, <<>>} = Wire.take_string(body)
    assert :json.decode(json)["version"]["protocol"] == 777
    assert {1, <<42::signed-64>>, _} = Client.read(client)
  end

  test "compressed login loads a world and commands work" do
    username = name("Login")
    {uuid, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    assert uuid == Valimc.Connection.offline_uuid(username)
    client = Client.load_world(client)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {body, _} = Client.await(client, :play, "system_chat")
    assert :binary.match(body, "schedulers") != :nomatch
    Client.send_packet(client, :play, "chat_command", Wire.string("spawn"))
    {teleport, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", teleport)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_body, _} = Client.await(client, :play, "system_chat")
  end

  test "one killed player leaves peers and listener running" do
    first_name = name("Kill")
    {_, first} = Client.login(first_name)
    on_exit(fn -> Client.close(first) end)
    {_, second} = Client.login(name("Alive"))
    on_exit(fn -> Client.close(second) end)
    first_player = Enum.find(Valimc.Players.all(), &(&1.name == first_name))
    Process.exit(first_player.pid, :kill)
    Client.send_packet(second, :play, "chat_command", Wire.string("stats"))
    {_body, second} = Client.await(second, :play, "system_chat")
    assert Process.alive?(Process.whereis(Valimc.Listener))
    Client.send_packet(second, :play, "chat_command", Wire.string("stats"))
    {_body, _} = Client.await(second, :play, "system_chat")
  end

  test "malformed and wrong-version clients do not affect the listener" do
    bad = Client.connect()
    Client.send_raw(bad, <<128, 128, 128, 128, 16>>)
    assert {:error, :closed} = :gen_tcp.recv(bad.socket, 0, 1000)
    other = Client.connect()
    on_exit(fn -> Client.close(other) end)

    Client.send_packet(other, :handshake, "intention", [
      Wire.varint(767),
      Wire.string("localhost"),
      <<25565::16, 2>>
    ])

    {id, body, _} = Client.read(other)
    assert id == Data.id(:login, :clientbound, "login_disconnect")
    assert :binary.match(body, "26.3") != :nomatch
  end

  test "unreachable block actions cannot allocate regions" do
    {_, client} = Client.login(name("Reach"))
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    before_count = DynamicSupervisor.count_children(Valimc.RegionSupervisor).active

    Client.send_packet(client, :play, "player_action", [
      <<0>>,
      Wire.position({29_000_000, 64, 29_000_000}),
      <<1, 42>>
    ])

    {<<42>>, _} = Client.await(client, :play, "block_changed_ack")
    assert DynamicSupervisor.count_children(Valimc.RegionSupervisor).active == before_count
  end

  test "peer updates publish the latest movement from a burst" do
    {_, sender} = Client.login(name("Move"))
    on_exit(fn -> Client.close(sender) end)
    {_, receiver} = Client.login(name("See"))
    on_exit(fn -> Client.close(receiver) end)
    receiver = Client.load_world(receiver)

    frames =
      for n <- 1..20 do
        Wire.frame(
          Data.id(:play, :serverbound, "move_player_pos"),
          <<0.5 + n * 0.015::float-64, 64.0::float-64, 0.5::float-64, 1>>,
          sender.threshold
        )
      end

    Client.send_raw(sender, frames)
    {body, _} = Client.await(receiver, :play, "move_entity_pos_rot")

    {_entity, <<1, dx::signed-16, 0::signed-16, 0::signed-16, _yaw, _pitch>>} =
      Wire.take_varint(body)

    assert dx == 1229
  end

  test "mailbox overload terminates only the slow connection" do
    username = name("Slow")
    {_, slow} = Client.login(username)
    on_exit(fn -> Client.close(slow) end)
    {_, healthy} = Client.login(name("Fast"))
    on_exit(fn -> Client.close(healthy) end)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    ref = Process.monitor(player.pid)
    :sys.suspend(player.pid)
    for _ <- 1..300, do: Valimc.Connection.deliver(player.pid, {:chat, "load"})
    assert_receive {:DOWN, ^ref, :process, _, :killed}, 1000
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_body, _} = Client.await(healthy, :play, "system_chat")
  end
end
