defmodule Valimc.ClientTickTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.TestClient, as: Client

  test "ordered client ticks share a TCP batch; server publication cannot release admission" do
    {client, player} = login()
    {healthy, peer} = login()

    Client.send_raw(client, [
      frame(client, "move_player_pos", position(1.5)),
      frame(client, "move_player_rot", <<90.0::float-32, 0.0::float-32, 1>>),
      frame(client, "move_player_status_only", <<3>>),
      frame(client, "client_tick_end", <<>>),
      frame(
        client,
        "move_player_pos_rot",
        <<2.5::float-64, 64.0::float-64, 0.5::float-64, 45.0::float-32, 0.0::float-32, 1>>
      )
    ])

    client = barrier(client)
    Client.await_position(player.pid, %{x: 2.5})
    state = :sys.get_state(player.pid)
    assert state.player.x == 2.5 and state.player.yaw == 45.0
    assert state.client_tick.position_received?
    send(player.pid, :publish_movement)
    client = barrier(client)
    assert :sys.get_state(player.pid).client_tick.position_received?

    # A different socket still has its own unused client frame.
    Client.send_packet(healthy, :play, "move_player_pos", position(3.5))
    healthy = barrier(healthy)
    Client.await_position(peer.pid, %{x: 3.5})
    assert :sys.get_state(peer.pid).player.x == 3.5
    ref = Process.monitor(player.pid)
    Client.send_packet(client, :play, "move_player_pos", position(4.5))
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    _healthy = barrier(healthy)
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  test "duplicate position is rejected while initial teleport and client load are pending" do
    name = username()
    {_, client} = Client.configure(name)
    on_exit(fn -> Client.close(client) end)
    [{pid, _}] = Enum.filter(:ets.tab2list(Valimc.Players), fn {_, p} -> p.name == name end)
    ref = Process.monitor(pid)

    Client.send_raw(client, [
      Wire.frame(
        Data.id(:configuration, :serverbound, "finish_configuration"),
        <<>>,
        client.threshold
      ),
      frame(client, "move_player_pos", position(1.5)),
      frame(
        client,
        "move_player_pos_rot",
        <<2.5::float-64, 64.0::float-64, 0.5::float-64, 0.0::float-32, 0.0::float-32, 1>>
      )
    ])

    body = await_disconnect(client)
    assert :binary.match(body, "Invalid player movement") != :nomatch
    assert_receive {:DOWN, ^ref, :process, _, :normal}
    assert Process.alive?(Process.whereis(Valimc.Listener))
  end

  defp username, do: "Tick" <> Integer.to_string(System.unique_integer([:positive]))

  defp login(name \\ username()) do
    {_, client} = Client.login(name)
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)
    player = Enum.find(Valimc.Players.all(), &(&1.name == name))
    {client, player}
  end

  defp position(x), do: <<x::float-64, 64.0::float-64, 0.5::float-64, 1>>

  defp frame(client, name, body),
    do: Wire.frame(Data.id(:play, :serverbound, name), body, client.threshold)

  defp barrier(client) do
    Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {_body, client} = Client.await_stats(client)
    client
  end

  # Initial teleport is deliberately unacknowledged; don't auto-reply while reading rejection.
  defp await_disconnect(client, remaining \\ 64)
  defp await_disconnect(_, 0), do: flunk("Expected movement disconnect")

  defp await_disconnect(client, remaining) do
    {id, body, client} = Client.read(client)

    if id == Data.id(:play, :clientbound, "disconnect"),
      do: body,
      else: await_disconnect(client, remaining - 1)
  end
end
