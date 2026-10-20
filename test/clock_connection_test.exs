defmodule Valimc.ClockConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.Protocol.Wire
  alias Valimc.World.{Clock, ClockRecord}

  # Probe totals are small positive values. Independent Mojang value fixtures
  # cover signed VarLong boundaries; its TCP oracle checks negotiated holders.
  defp decode(<<game_time::signed-64, body::binary>>) do
    {2, body} = Wire.take_varint(body)

    {clocks, <<>>} =
      Enum.reduce(1..2, {%{}, body}, fn _, {acc, bytes} ->
        {id, bytes} = Wire.take_varint(bytes)
        {ticks, <<partial::float-32, rate::float-32, rest::binary>>} = Wire.take_varint(bytes)
        {Map.put(acc, id, {ticks, partial, rate}), rest}
      end)

    {game_time, clocks}
  end

  test "real TCP login and periodic clock maps, immediate pause updates and continuing session actions" do
    # Earlier tests may have set or stopped the clocks; running ones keep a fixed
    # offset from the game time.
    assert :ok = Clock.configure({:advance_time, true})

    for name <- ClockRecord.names() do
      assert :ok = Clock.configure({name, :paused, false})
      assert :ok = Clock.configure({name, :rate, 1.0})
    end

    before = Clock.snapshot()

    offsets =
      ClockRecord.names()
      |> Enum.with_index()
      |> Map.new(fn {name, id} -> {id, before.clocks[name].total_ticks - before.game_time} end)

    client = Client.begin_login("ClockProbe")
    {_uuid, client} = Client.configure_session(client, "ClockProbe")
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")

    on_exit(fn ->
      Client.close(client)
      Clock.configure({:advance_time, true})
      Clock.configure({"minecraft:overworld", :paused, false})
    end)

    {body, client} = Client.await(client, :play, "set_time")
    {time, clocks} = decode(body)
    assert Map.keys(clocks) |> Enum.sort() == [0, 1]

    assert clocks[0] == {time + offsets[0], 0.0, 1.0} and
             clocks[1] == {time + offsets[1], 0.0, 1.0}

    {body, client} = Client.await(client, :play, "set_time")
    {next, clocks} = decode(body)
    assert next >= time and next - time <= 20
    assert clocks[0] == {next + offsets[0], 0.0, 1.0}
    {body, client} = Client.await(client, :play, "set_time")
    {later, _} = decode(body)
    assert later - next == 20
    assert :ok = Clock.configure({"minecraft:overworld", :paused, true})
    {body, client} = Client.await(client, :play, "set_time")
    {_time, clocks} = decode(body)
    assert elem(clocks[0], 2) == 0.0 and elem(clocks[1], 2) == 1.0
    client = Client.send_packet(client, :play, "chat_command", Wire.string("stats"))
    {body, _client} = Client.await(client, :play, "system_chat")
    assert is_binary(body) and byte_size(body) > 0
  end
end
