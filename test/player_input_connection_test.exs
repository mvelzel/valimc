defmodule Valimc.PlayerInputConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.{Data, Wire}

  test "pre-load input is retained, completion does not replay it, self and peer flags are paced" do
    {sender, player} = login("Input")
    {receiver, _} = login("Observe")
    assert receiver.entity_flags[player.entity_id] == 0

    Client.send_packet(sender, :play, "player_input", <<96>>)
    Client.send_packet(sender, :play, "player_command", command(1))
    sender = barrier(sender)
    assert current(player).input.buttons == 96
    assert current(player).input.shared_flags == 0
    Client.send_packet(sender, :play, "player_loaded", <<>>)
    sender = barrier(sender)
    assert current(player).input.shared_flags == 0

    # Queue both frames before the owner resumes, then observe its coalesced flags.
    :sys.suspend(player.pid)

    frames = [
      frame(sender, "player_input", <<32>>),
      frame(sender, "player_command", command(1, -1))
    ]

    Client.send_raw(sender, frames)
    :sys.resume(player.pid)
    sender = await_flags(sender, player.entity_id, 10)
    sender = barrier(sender)
    assert current(player).input.shared_flags == 10
    receiver = await_flags(receiver, player.entity_id, 10)

    Client.send_packet(sender, :play, "player_input", <<64>>)
    sender = barrier(sender)
    assert current(player).input.shared_flags == 8
    receiver = await_flags(receiver, player.entity_id, 8)
    Client.send_packet(sender, :play, "player_command", command(2))
    _sender = barrier(sender)
    _receiver = await_flags(receiver, player.entity_id, 0)
  end

  test "late observers and tracking recreation initialize nondefault flags; reconnect resets input" do
    username = name("Late")
    {sender, player} = login_name(username)
    Client.send_packet(sender, :play, "player_loaded", <<>>)

    Client.send_raw(sender, [
      frame(sender, "player_input", <<32>>),
      frame(sender, "player_command", command(1))
    ])

    sender = barrier(sender)
    {receiver, _} = login("Later")
    assert receiver.entity_flags[player.entity_id] == 10

    Client.send_packet(
      sender,
      :play,
      "move_player_pos",
      <<10.0::float-64, 64.0::float-64, 0.5::float-64, 1>>
    )

    receiver = await_flags(receiver, player.entity_id, 10)

    Client.send_packet(sender, :play, "client_tick_end", <<>>)

    Client.send_packet(
      sender,
      :play,
      "move_player_pos",
      <<1024.5::float-64, 64.0::float-64, 0.5::float-64, 1>>
    )

    {_removed, receiver} = Client.await(receiver, :play, "remove_entities")

    Client.send_packet(sender, :play, "client_tick_end", <<>>)

    Client.send_packet(
      sender,
      :play,
      "move_player_pos",
      <<0.5::float-64, 64.0::float-64, 0.5::float-64, 1>>
    )

    _receiver = await_flags(receiver, player.entity_id, 10)

    ref = Process.monitor(player.pid)
    Client.close(sender)
    assert_receive {:DOWN, ^ref, :process, _, _}, 1000
    {_reconnected, new_player} = login_name(username)
    assert new_player.input.buttons == 0
    assert new_player.input.shared_flags == 0
  end

  test "unchanged or flags-only observations generate no redundant movement; command IDs cannot target peers" do
    {sender, player} = login("Quiet")
    {receiver, receiver_player} = login("Peer")
    assert receiver.entity_flags[player.entity_id] == 0
    Client.send_packet(sender, :play, "player_loaded", <<>>)
    Client.send_packet(sender, :play, "player_command", command(1, receiver_player.entity_id))
    sender = barrier(sender)
    receiver = await_flags(receiver, player.entity_id, 8, true)
    assert current(receiver_player).input.shared_flags == 0
    Client.send_packet(sender, :play, "player_command", command(1))
    Client.send_packet(sender, :play, "player_input", <<64>>)
    _sender = barrier(sender)
    # Deliver at least three publication intervals; only packet events are examined below.
    Process.sleep(160)
    Client.send_packet(receiver, :play, "chat_command", Wire.string("stats"))
    _receiver = await_stats_without_replication(receiver, player.entity_id)
  end

  test "malformed input, command and loaded packets disconnect only their sender" do
    {healthy, _} = login("Healthy")

    for {packet, payload} <- [
          {"player_input", <<32, 0>>},
          {"player_command", <<1, 7, 0>>},
          {"player_loaded", <<1>>}
        ] do
      {bad, player} = login("Invalid")
      Client.send_packet(bad, :play, "player_loaded", <<>>)
      Client.send_packet(bad, :play, "player_input", <<32>>)
      bad = barrier(bad)
      assert current(player).input.shared_flags == 2
      ref = Process.monitor(player.pid)
      Client.send_packet(bad, :play, packet, payload)
      assert_receive {:DOWN, ^ref, :process, _, :normal}, 1000
      assert Process.alive?(Process.whereis(Valimc.Listener))
    end

    _healthy = barrier(healthy)
  end

  defp login(prefix), do: login_name(name(prefix))
  defp name(prefix), do: prefix <> Integer.to_string(System.unique_integer([:positive]))

  defp login_name(username) do
    {_, client} = Client.login(username)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    player = Enum.find(Valimc.Players.all(), &(&1.name == username))
    {client, player}
  end

  defp current(player), do: :sys.get_state(player.pid).player

  defp command(action, id \\ 300),
    do: IO.iodata_to_binary([Wire.varint(id), Wire.varint(action), <<0>>])

  defp frame(client, name, body),
    do: Wire.frame(Data.id(:play, :serverbound, name), body, client.threshold)

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_body, client} = Client.await(client, :play, "system_chat")
    client
  end

  defp await_flags(client, entity, flags, forbid_movement \\ false) do
    {id, body, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)

    case {name, Wire.read_varint(body)} do
      {"set_entity_data", {:ok, ^entity, <<0, 0, ^flags, 255>>}} ->
        client

      {"move_entity_pos_rot", {:ok, ^entity, _}} when forbid_movement ->
        flunk("Flags fabricated movement")

      _ ->
        await_flags(Client.auto_reply(client, :play, name, body), entity, flags, forbid_movement)
    end
  end

  defp await_stats_without_replication(client, entity) do
    {id, body, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)

    if name in ["set_entity_data", "move_entity_pos_rot"] do
      {other, _} = Wire.take_varint(body)
      refute other == entity
    end

    if name == "system_chat",
      do: client,
      else: await_stats_without_replication(Client.auto_reply(client, :play, name, body), entity)
  end
end
