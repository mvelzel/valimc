defmodule Valimc.ViewDistanceConnectionTest do
  # VMC-070: the client's requested view distance decides which chunks it gets.
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.Player.PlayerList
  alias Valimc.{Protocol.Data, Protocol.Wire}
  alias Valimc.Player.ChunkView
  alias Valimc.TestClient, as: Client

  setup do
    old = Application.fetch_env!(:valimc, :view_distance)
    Application.put_env(:valimc, :view_distance, 10)
    on_exit(fn -> Application.put_env(:valimc, :view_distance, old) end)
  end

  defp settings(distance),
    do: [Wire.string("en_us"), <<distance::signed-8, 0, 1, 0x7F, 1, 0, 1, 0>>]

  # Joins with `distance` sent during configuration, as the vanilla client does.
  defp join(distance) do
    name = "View#{System.unique_integer([:positive])}"
    {uuid, client} = Client.configure_session(Client.begin_login(name), name)
    on_exit(fn -> Client.close(client) end)
    client = Client.send_packet(client, :configuration, "client_information", settings(distance))
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {login, client} = Client.await(client, :play, "login")
    {position, client} = Client.await(client, :play, "player_position")

    {_, <<x::float-64, _y::float-64, z::float-64, _::binary>>} = Wire.take_varint(position)
    client = Client.auto_reply(client, :play, "player_position", position)
    <<_entity::32, 0, rest::binary>> = login
    {dimensions, rest} = Wire.take_varint(rest)
    rest = Enum.reduce(1..dimensions, rest, fn _, rest -> elem(Wire.take_string(rest), 1) end)
    {_max_players, rest} = Wire.take_varint(rest)
    {chunk_radius, rest} = Wire.take_varint(rest)
    {simulation, _} = Wire.take_varint(rest)
    owner = owner(uuid)

    %{
      client: client,
      owner: owner,
      center: {floor_div(x), floor_div(z)},
      radius: chunk_radius,
      simulation: simulation
    }
  end

  defp owner(uuid, _budget \\ nil),
    do:
      Valimc.TestWait.until(fn ->
        Enum.find_value(PlayerList.all(), &if(&1.uuid == uuid, do: &1.pid))
      end)

  defp floor_div(coordinate), do: Integer.floor_div(floor(coordinate), 16)

  # Reads until `count` chunks arrived, then until 300 ms pass quietly (six ticks):
  # `{chunks, forgotten, batch sizes, client}`.
  defp stream(client, count, acc \\ {[], [], []})

  defp stream(client, count, {chunks, forgotten, batches}) when length(chunks) >= count do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, body, rest} ->
        receive_packet(%{client | buffer: rest}, id, body, count, {chunks, forgotten, batches})

      :more ->
        case :gen_tcp.recv(client.socket, 0, 300) do
          {:ok, bytes} ->
            stream(
              %{client | buffer: client.buffer <> bytes},
              count,
              {chunks, forgotten, batches}
            )

          {:error, :timeout} ->
            {chunks, forgotten, Enum.reverse(batches), client}
        end
    end
  end

  defp stream(client, count, acc) do
    {id, body, client} = Client.read(client)
    receive_packet(client, id, body, count, acc)
  end

  defp receive_packet(client, id, body, count, {chunks, forgotten, batches}) do
    name = Data.name(:play, :clientbound, id)
    client = Client.auto_reply(client, :play, name, body)

    acc =
      case {name, body} do
        {"level_chunk_with_light", <<x::signed-32, z::signed-32, _::binary>>} ->
          {[{x, z} | chunks], forgotten, batches}

        {"forget_level_chunk", <<z::signed-32, x::signed-32>>} ->
          {chunks, [{x, z} | forgotten], batches}

        {"chunk_batch_finished", size} ->
          {chunks, forgotten, [elem(Wire.take_varint(size), 0) | batches]}

        _ ->
          {chunks, forgotten, batches}
      end

    stream(client, count, acc)
  end

  defp view(center, distance), do: MapSet.new(ChunkView.chunks({center, distance}))

  test "the client's distance picks the chunks; changing it in play streams and forgets the difference" do
    joined = join(4)
    # The login packet carries the server's distances; the client's own picks the view.
    assert joined.radius == 10 and joined.simulation == 10
    {chunks, forgotten, batches, client} = stream(joined.client, 117)
    assert length(chunks) == 117 and forgotten == []
    assert MapSet.new(chunks) == view(joined.center, 4)
    # Vanilla's first batch is bounded by its starting rate, later ones by the
    # client's; chunks of a region still loading wait for a later batch.
    assert hd(batches) <= 9 and Enum.all?(batches, &(&1 <= 64)) and Enum.sum(batches) == 117

    # Yet the chunks within the simulation distance load and tick, as vanilla's
    # (VMC-077e1).
    {cx, cz} = joined.center
    square = MapSet.new(for x <- (cx - 10)..(cx + 10), z <- (cz - 10)..(cz + 10), do: {x, z})
    wanted = Map.values(Valimc.TestConn.state(joined.owner).wanted)

    assert Enum.reduce(wanted, MapSet.new(), fn {_, _, s}, acc -> MapSet.union(acc, s) end) ==
             square

    loading = Enum.reduce(wanted, MapSet.new(), fn {_, l, _}, acc -> MapSet.union(acc, l) end)
    assert loading == MapSet.union(square, view(joined.center, 4))

    client = Client.send_packet(client, :play, "client_information", settings(6))
    {chunks, forgotten, _, client} = stream(client, 213 - 117)
    assert forgotten == []
    assert MapSet.new(chunks) == MapSet.difference(view(joined.center, 6), view(joined.center, 4))

    client = Client.send_packet(client, :play, "client_information", settings(3))
    {chunks, forgotten, _, client} = stream(client, 0)
    assert chunks == [] and length(forgotten) == 213 - 81

    assert MapSet.new(forgotten) ==
             MapSet.difference(view(joined.center, 6), view(joined.center, 3))

    state = Valimc.TestConn.state(joined.owner)
    assert state.view == {joined.center, 3} and state.chunks == view(joined.center, 3)

    # The same distance again changes nothing.
    client = Client.send_packet(client, :play, "client_information", settings(3))
    assert {[], [], [], _} = stream(client, 0)
  end
end
