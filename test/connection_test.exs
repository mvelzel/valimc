defmodule Valimc.ConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
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
    {body, _} = Client.await_stats(client)
    assert :binary.match(body, "schedulers") != :nomatch
    Client.send_packet(client, :play, "chat_command", Wire.string("spawn"))
    {teleport, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", teleport)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_body, _} = Client.await_stats(client)
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

  # Reads until the server closes the socket (a disconnect packet may come first).
  defp closed?(client) do
    case :gen_tcp.recv(client.socket, 0, 5000) do
      {:ok, _} -> closed?(client)
      {:error, :closed} -> true
      {:error, _} -> false
    end
  end

  test "frames before configuration are small; a larger one closes the connection" do
    # A handshake frame announcing 2 KiB ends the connection before its body (VMC-077a).
    big = Client.connect()
    Client.send_raw(big, Wire.varint(2048) <> :binary.copy(<<0>>, 64))
    assert closed?(big)

    # A 40 KiB frame in login exceeds the login buffer.
    login = Client.connect()

    Client.send_packet(login, :handshake, "intention", [
      Wire.varint(777),
      Wire.string("localhost"),
      <<25565::16, 2>>
    ])

    Client.send_raw(login, Wire.frame(0, :binary.copy(<<0>>, 40_000)))
    assert closed?(login)

    # A player in play may still send frames up to `max_packet_bytes`.
    {_, client} = Client.login(name("Frames"))
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    assert Valimc.Connection.frame_limit(%{phase: :play}) == Valimc.config(:max_packet_bytes)
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_body, _} = Client.await_stats(client)
  end

  test "chat with illegal characters ends the session, as commands do" do
    {_, client} = Client.login(name("Illegal"))
    client = Client.load_world(client)

    Client.send_packet(client, :play, "chat", [
      Wire.string("hi \u00a7cred"),
      <<0::64, 0::64, 0, 0, 0, 0, 0>>
    ])

    {body, _} = Client.await(client, :play, "disconnect")
    assert :binary.match(body, "Illegal characters") != :nomatch
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
    sender_name = name("Move")
    {_, sender} = Client.login(sender_name)
    on_exit(fn -> Client.close(sender) end)
    {_, receiver} = Client.login(name("See"))
    on_exit(fn -> Client.close(receiver) end)
    receiver = Client.load_world(receiver)

    frames =
      for n <- 1..20 do
        [
          Wire.frame(
            Data.id(:play, :serverbound, "move_player_pos"),
            <<0.5 + n * 0.015::float-64, 64.0::float-64, 0.5::float-64, 1>>,
            sender.threshold
          ),
          Wire.frame(Data.id(:play, :serverbound, "client_tick_end"), <<>>, sender.threshold)
        ]
      end

    Client.send_raw(sender, frames)
    # Peers get the latest position per publication, not one packet per input. On a
    # loaded host the burst may straddle a publication, so sum the sender's deltas
    # (VMC-073).
    entity = Enum.find(Valimc.Players.all(), &(&1.name == sender_name)).entity_id
    {dx, packets} = coalesced_moves(receiver, entity, 1229)
    assert dx == 1229 and packets < 20
  end

  defp coalesced_moves(client, entity, target, dx \\ 0, packets \\ 0) do
    {body, client} = Client.await(client, :play, "move_entity_pos_rot")

    case Wire.take_varint(body) do
      {^entity, <<1, step::signed-16, 0::signed-16, 0::signed-16, _yaw, _pitch>>} ->
        if dx + step >= target,
          do: {dx + step, packets + 1},
          else: coalesced_moves(client, entity, target, dx + step, packets + 1)

      _other ->
        coalesced_moves(client, entity, target, dx, packets)
    end
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
    # A stuck (here: suspended) connection cannot handle the graceful signal and is
    # killed by the fallback timer.
    assert_receive {:DOWN, ^ref, :process, _, :killed}
    Client.send_packet(healthy, :play, "chat_command", Wire.string("stats"))
    {_body, _} = Client.await_stats(healthy)
  end

  defp drain(client, names \\ []) do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, _body, rest} ->
        drain(%{client | buffer: rest}, [Data.name(:play, :clientbound, id) | names])

      :more ->
        case :gen_tcp.recv(client.socket, 0, 30) do
          {:ok, bytes} -> drain(%{client | buffer: client.buffer <> bytes}, names)
          {:error, :timeout} -> {client, names}
        end
    end
  end

  test "configuration ack and early chunk feedback cannot stream before valid play teleport confirmation" do
    name = "Ready#{System.unique_integer([:positive])}"
    {uuid, client} = Client.configure_session(Client.begin_login(name), name)

    on_exit(fn ->
      Client.close(client)

      for player <- Valimc.Players.all(),
          player.uuid == uuid,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)
    end)

    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {teleport, client} = Client.await(client, :play, "player_position")
    {_, client} = Client.await(client, :play, "system_chat")

    owner =
      Valimc.TestWait.until(fn ->
        Enum.find_value(Valimc.Players.all(), &if(&1.uuid == uuid, do: &1.pid))
      end)

    # Force the pending stream event while a real TCP peer withholds its play ack.
    send(owner, :send_chunks)
    state = :sys.get_state(owner)
    {client, names} = drain(client)

    refute Enum.any?(
             names,
             &(&1 in ~w(chunk_batch_start level_chunk_with_light chunk_batch_finished))
           )

    assert state.teleport_pending and state.pending != [] and
             state.chunk_sender.unacknowledged == 0

    assert state.chunks == MapSet.new()

    packets = state.packets
    window = state.window
    Client.send_packet(client, :play, "chunk_batch_received", <<8.0::float-32>>)

    Valimc.TestWait.until(fn ->
      current = :sys.get_state(owner)
      current.packets > packets or (current.window != window and current.packets > 0)
    end)

    send(owner, :send_chunks)
    assert :sys.get_state(owner).teleport_pending
    {client, names} = drain(client)

    refute Enum.any?(
             names,
             &(&1 in ~w(chunk_batch_start level_chunk_with_light chunk_batch_finished))
           )

    client = Client.auto_reply(client, :play, "player_position", teleport)
    client = Client.load_world(client)
    state = :sys.get_state(owner)
    refute state.teleport_pending
    assert MapSet.size(state.chunks) >= 49
    Client.close(client)
  end
end
