defmodule Valimc.WeatherConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :tcp
  alias Valimc.TestClient, as: Client
  alias Valimc.World.Clock

  defp event(client, predicate, remaining \\ 200) do
    assert remaining > 0
    {<<type, value::float-32>>, client} = Client.await(client, :play, "game_event")

    if predicate.(type, value),
      do: {type, value, client},
      else: event(client, predicate, remaining - 1)
  end

  # The start/stop events fire when the rain level crosses 0.2, and the level ramps
  # by 0.01 per tick: start dry, even if an earlier test (or the natural cycle)
  # left rain fading out.
  defp dry(attempts \\ 400) do
    weather = Clock.snapshot().weather

    cond do
      weather.rain_level == 0.0 and weather.thunder_level == 0.0 ->
        :ok

      attempts > 0 ->
        Process.sleep(25)
        dry(attempts - 1)

      true ->
        flunk("weather did not clear: #{inspect(weather)}")
    end
  end

  test "real TCP weather ramp, start/stop event thresholds, cycle freeze and continuing commands" do
    on_exit(fn ->
      Clock.configure({:advance_weather, true})
      Clock.configure({:weather, :clear, 0})
    end)

    assert :ok = Clock.configure({:advance_weather, false})
    assert :ok = Clock.configure({:weather, :clear, 0})
    dry()
    {_uuid, client} = Client.login("WeatherProbe")
    on_exit(fn -> Client.close(client) end)
    client = Client.load_world(client)

    assert :ok = Clock.configure({:weather, :thunder, 600})
    {1, +0.0, client} = event(client, fn type, _ -> type == 1 end)
    {8, value, client} = event(client, fn type, value -> type == 8 and value >= 0.25 end)
    assert value <= 1.0
    frozen = Clock.snapshot().weather
    assert frozen.rain_time == 600 and frozen.thunder_time == 600
    assert :ok = Clock.configure({:weather, :clear, 0})
    {2, +0.0, client} = event(client, fn type, _ -> type == 2 end)
    {7, +0.0, client} = event(client, fn type, value -> type == 7 and value == 0.0 end)

    client =
      Client.send_packet(client, :play, "chat_command", Valimc.Protocol.Wire.string("stats"))

    {body, _} = Client.await(client, :play, "system_chat")
    assert byte_size(body) > 0
  end
end
