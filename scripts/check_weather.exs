alias Valimc.World.{Weather, WeatherReplication}
[input] = System.argv()
cases = File.read!(input) |> :json.decode()

for fixture <- cases do
  weather = %Weather{
    clear_time: fixture["clear"],
    rain_time: fixture["timer"],
    thunder_time: fixture["timer"],
    raining: Bitwise.band(fixture["flags"], 1) != 0,
    thundering: Bitwise.band(fixture["flags"], 2) != 0,
    advance_weather: fixture["advance"],
    random_seed: fixture["seed"]
  }

  true = Weather.valid?(weather)

  Enum.reduce(fixture["trace"], weather, fn expected, previous ->
    actual = Weather.tick(previous)

    true =
      actual.clear_time == expected["clear"] and actual.rain_time == expected["rain_time"] and
        actual.thunder_time == expected["thunder_time"]

    true =
      actual.raining == expected["raining"] and actual.thundering == expected["thundering"] and
        actual.random_seed == expected["seed"]

    true =
      <<actual.rain_level::float-32>> == <<expected["rain"]::float-32>> and
        <<actual.thunder_level::float-32>> == <<expected["thunder"]::float-32>>

    {_, events} =
      WeatherReplication.reconcile(
        WeatherReplication.cache(previous),
        WeatherReplication.cache(actual)
      )

    encoded = Enum.map(events, fn {_, body} -> Base.encode16(body, case: :lower) end)

    if encoded != expected["events"],
      do: raise("Native weather event order differs: #{inspect({encoded, expected["events"]})}")

    actual
  end)
end

IO.puts(
  "PASS: #{length(cases)} native weather traces / #{length(cases) * 105} ticks match timers, flags, random draws, intensities and exact event order."
)
