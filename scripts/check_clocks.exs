alias Valimc.World.ClockState
[input, output] = System.argv()
cases = File.read!(input) |> :json.decode()

encoded =
  Enum.map(cases, fn fixture ->
    clock = %ClockState{
      total_ticks: fixture["initial_total"],
      partial_tick: fixture["initial_partial"],
      rate: fixture["initial_rate"],
      paused: fixture["paused"]
    }

    true = ClockState.valid?(clock)

    clock =
      Enum.reduce(List.duplicate(nil, fixture["ticks"]), clock, fn _, current ->
        if fixture["advance"], do: ClockState.tick(current), else: current
      end)

    true = clock.total_ticks == fixture["total"]
    true = <<clock.partial_tick::float-32>> == <<fixture["partial"]::float-32>>
    bytes = ClockState.network(clock, fixture["advance"]) |> IO.iodata_to_binary()
    true = Base.encode16(bytes, case: :lower) == fixture["encoded"]
    Map.put(fixture, "encoded", Base.encode16(bytes, case: :lower))
  end)

File.write!(output, :json.encode(encoded))

IO.puts(
  "PASS: #{length(cases)} native clock cases match Elixir float32 arithmetic, pause/global advance and network bytes."
)
