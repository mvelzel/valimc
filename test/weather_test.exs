defmodule Valimc.WeatherTest do
  use ExUnit.Case, async: true
  alias Valimc.World.{Clock, ClockRecord, ClockState, Weather, WeatherReplication}

  test "clear override, expiration, timer refill order and owned random state" do
    weather = %Weather{
      clear_time: 1,
      rain_time: 2,
      thunder_time: 3,
      raining: true,
      thundering: true,
      random_seed: Weather.seed(0)
    }

    clear = Weather.tick(weather)
    assert clear.clear_time == 0 and clear.rain_time == 0 and clear.thunder_time == 0
    refute clear.raining or clear.thundering
    assert clear.random_seed == weather.random_seed
    sampled = Weather.tick(clear)
    assert sampled.rain_time in 12000..180_000 and sampled.thunder_time in 12000..180_000
    refute sampled.raining or sampled.thundering
    assert sampled.random_seed != clear.random_seed
    toggled = Weather.tick(%{clear | rain_time: 1, thunder_time: 1})
    assert toggled.raining and toggled.thundering and toggled.rain_time == 0
    assert toggled.rain_level == ClockState.float32(0.01)
  end

  test "frozen weather cycle still completes intensity transitions and remains independent of time" do
    weather = %Weather{
      rain_time: 12,
      thunder_time: 13,
      raining: true,
      thundering: true,
      advance_weather: false
    }

    completed = Enum.reduce(1..105, weather, fn _, current -> Weather.tick(current) end)

    assert completed.rain_time == 12 and completed.thunder_time == 13 and
             completed.random_seed == 0

    assert completed.rain_level == 1.0 and completed.thunder_level == 1.0

    data = %{
      ClockRecord.new()
      | advance_time: false,
        weather: %Weather{rain_time: 2, thunder_time: 2}
    }

    next = ClockRecord.tick(data)
    assert next.clocks == data.clocks and next.weather.rain_time == 1
    assert Weather.tick(completed, false) == completed
  end

  test "intensity threshold, native event ordering, coalescing and fixed event bound" do
    before = %Weather{raining: true, thundering: true, advance_weather: false}
    ramp = Enum.reduce(1..19, before, fn _, current -> Weather.tick(current) end)
    refute Weather.wet?(ramp)
    next = Weather.tick(ramp)
    assert Weather.wet?(next)

    {view, packets} =
      WeatherReplication.reconcile(WeatherReplication.cache(ramp), WeatherReplication.cache(next))

    assert Enum.map(packets, fn {_, <<type, _::binary>>} -> type end) == [7, 8, 1, 7, 8]
    assert WeatherReplication.reconcile(view, view) == {view, []}
    initial = WeatherReplication.cache(before)

    {_, packets} =
      WeatherReplication.reconcile(
        initial,
        WeatherReplication.cache(%{next | rain_level: 1.0, thunder_level: 1.0})
      )

    assert length(packets) == 5
    assert WeatherReplication.cache(next, view) == view
  end

  test "weather presets validate and do not reset transient intensity or random history" do
    weather = %Weather{rain_level: 0.5, thunder_level: 0.25, random_seed: Weather.seed(123)}
    assert {:ok, rain} = Weather.configure(weather, :rain, 300)

    assert rain.raining and not rain.thundering and rain.rain_time == 300 and
             rain.thunder_time == 300

    assert rain.rain_level == 0.5 and rain.random_seed == weather.random_seed
    assert {:ok, storm} = Weather.configure(rain, :thunder, 400)
    assert storm.raining and storm.thundering
    assert {:ok, clear} = Weather.configure(storm, :clear, 500)
    assert clear.clear_time == 500 and clear.rain_time == 0 and clear.thunder_time == 0
    refute clear.raining or clear.thundering

    for {kind, duration} <- [{:missing, 1}, {:rain, -1}, {:rain, 2_147_483_648}, {:clear, 0.5}] do
      assert {:error, :invalid_weather_change} = Weather.configure(weather, kind, duration)
    end
  end

  test "record migration preserves old clocks, weather schema and native load preparation" do
    data = %{ClockRecord.new() | game_time: 12, advance_time: false}
    names = ClockRecord.names()

    body =
      IO.iodata_to_binary([
        <<"VMCLOCK", 1, 5023::32, 12::signed-64, 0, length(names)>>,
        Enum.map(names, fn _ -> <<0::signed-64, 0.0::float-32, 1.0::float-32, 0>> end)
      ])

    legacy = body <> :crypto.hash(:sha256, body)
    assert {:ok, loaded} = ClockRecord.decode(legacy)
    assert loaded.clocks == data.clocks and loaded.game_time == 12 and not loaded.advance_time
    assert loaded.weather.rain_level == 0.0 and Weather.valid?(loaded.weather)

    weather = %Weather{
      clear_time: 0,
      rain_time: 300,
      thunder_time: 250,
      raining: true,
      thundering: true,
      rain_level: 0.2,
      thunder_level: 0.1,
      advance_weather: false,
      random_seed: Weather.seed(44)
    }

    assert {:ok, bytes} = ClockRecord.encode(%{loaded | weather: weather})
    assert <<"VMCLOCK", 2, _::binary>> = bytes
    assert {:ok, recovered} = ClockRecord.decode(bytes)
    assert recovered.weather == Weather.prepare(weather)
    assert recovered.clocks == loaded.clocks
    # Vanilla prepares no initial thunder intensity when only the thunder flag is saved.
    assert Weather.prepare(%{weather | raining: false}).thunder_level == 0.0
    refute Weather.valid?(%{weather | random_seed: 0x1000000000000})

    assert {:error, :invalid_clock_state} =
             ClockRecord.encode(%{loaded | weather: %{weather | random_seed: -1}})
  end

  test "new world controls publish levels without per-player tick messages and persist weather" do
    path = Path.join(System.tmp_dir!(), "valimc-weather-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)

    pid =
      start_supervised!(
        {Clock, [name: nil, world_path: path, tick_interval_ms: nil, save_interval_ms: nil]}
      )

    assert :ok = Clock.configure({:weather, :thunder, 600}, pid)
    assert :ok = Clock.configure({:advance_weather, false}, pid)
    snapshot = Clock.snapshot(pid)
    assert snapshot.weather.raining and snapshot.weather.thundering
    assert :ok = Clock.flush(pid)
    stop_supervised!(Clock)

    pid =
      start_supervised!(
        {Clock, [name: nil, world_path: path, tick_interval_ms: nil, save_interval_ms: nil]}
      )

    recovered = Clock.snapshot(pid)
    assert recovered.weather == Weather.prepare(snapshot.weather)
    [{:weather, view}] = :ets.lookup(:sys.get_state(pid).table, :weather)
    assert view.wet and view.rain_level == 1.0 and view.thunder_level == 1.0
    assert {:error, :invalid_weather_change} = Clock.configure({:weather, :thunder, -1}, pid)
    assert Clock.snapshot(pid) == recovered
  end
end
