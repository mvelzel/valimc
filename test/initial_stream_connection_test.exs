defmodule Valimc.InitialStreamConnectionTest do
  use ExUnit.Case, async: false
  alias Valimc.{Players, Protocol.Data, Protocol.Wire}
  alias Valimc.TestClient, as: Client
  @chunks ~w(chunk_batch_start level_chunk_with_light chunk_batch_finished)

  defp wait(fun, attempts \\ 200) do
    if value = fun.() do
      value
    else
      assert attempts > 0
      Process.sleep(5)
      wait(fun, attempts - 1)
    end
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

      for player <- Players.all(),
          player.uuid == uuid,
          do: DynamicSupervisor.terminate_child(Valimc.ConnectionSupervisor, player.pid)
    end)

    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {teleport, client} = Client.await(client, :play, "player_position")
    {_, client} = Client.await(client, :play, "system_chat")
    owner = wait(fn -> Enum.find_value(Players.all(), &if(&1.uuid == uuid, do: &1.pid)) end)

    # Force the pending stream event while a real TCP peer withholds its play ack.
    send(owner, :send_chunks)
    state = :sys.get_state(owner)
    {client, names} = drain(client)
    refute Enum.any?(names, &(&1 in @chunks))
    assert state.teleport_pending and state.pending != [] and not state.batch_pending
    assert state.chunks == MapSet.new()

    packets = state.packets
    window = state.window
    Client.send_packet(client, :play, "chunk_batch_received", <<8.0::float-32>>)

    wait(fn ->
      current = :sys.get_state(owner)
      current.packets > packets or (current.window != window and current.packets > 0)
    end)

    send(owner, :send_chunks)
    assert :sys.get_state(owner).teleport_pending
    {client, names} = drain(client)
    refute Enum.any?(names, &(&1 in @chunks))

    client = Client.auto_reply(client, :play, "player_position", teleport)
    client = Client.load_world(client)
    state = :sys.get_state(owner)
    refute state.teleport_pending
    assert MapSet.size(state.chunks) >= 9
    Client.close(client)
  end
end
