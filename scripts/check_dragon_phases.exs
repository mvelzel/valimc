alias Valimc.AI.{Random, Dragon.Flight, Dragon.Paths, Dragon.Phases}

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

defmodule DragonPhaseCheck do
  def equal(actual, expected, label) when is_tuple(actual),
    do: equal(Tuple.to_list(actual), expected, label)

  def equal(actual, expected, label) when is_list(actual) do
    if length(actual) != length(expected),
      do: raise("#{label}: lengths differ #{inspect({actual, expected})}")

    Enum.zip(actual, expected) |> Enum.each(fn {a, b} -> equal(a, b, label) end)
  end

  def equal(actual, expected, label) when is_number(actual) and is_number(expected) do
    if abs(actual - expected) > 1.0e-9,
      do: raise("#{label}: #{inspect(actual)} differs from #{inspect(expected)}")
  end

  def equal(actual, actual, _label), do: :ok

  def equal(actual, expected, label),
    do: raise("#{label}: #{inspect(actual)} differs from #{inspect(expected)}")
end

for row <- raw["cases"] do
  env = %{
    graph: Paths.graph(fn _, _ -> 90 end),
    podium: {0, 90, 0},
    crystals: if(row["crystals"] < 0, do: nil, else: row["crystals"]),
    players:
      Enum.map(
        row["players"],
        &%{id: &1["id"], position: List.to_tuple(&1["position"]), height: &1["height"]}
      ),
    visible: fn _ -> row["scene"] != 3 end,
    solid: fn {_, y, _} -> y < if(row["scene"] == 3, do: 0, else: 70) end
  }

  flight = %Flight{position: List.to_tuple(row["position"]), yaw: 25.0}

  state =
    Phases.set(
      %Phases{flight: flight, head_yaw: 25.0, random: Random.new(4519 + row["scene"])},
      row["start_phase"]
    )

  player = List.first(env.players)

  state =
    cond do
      state.phase == 1 and player -> Phases.strafe(state, player, env)
      state.phase == 8 and player -> %{state | target: player.position}
      true -> state
    end

  Enum.with_index(row["ticks"])
  |> Enum.reduce(state, fn {tick, index}, state ->
    players =
      if tick["player_present"],
        do: Enum.map(env.players, &%{&1 | position: List.to_tuple(tick["player_position"])}),
        else: []

    state =
      Phases.tick(
        state,
        env |> Map.put(:players, players) |> Map.put(:collision, tick["collision"])
      )

    label =
      "start #{row["start_phase"]} scene #{row["scene"]} crystals #{row["crystals"]} tick #{index}"

    for {key, actual} <- [
          {"phase", state.phase},
          {"target", state.target},
          {"random", state.random},
          {"path", state.path},
          {"flames", state.flames}
        ],
        do: DragonPhaseCheck.equal(actual, tick[key], label <> " " <> key)

    if tick["ticks"], do: DragonPhaseCheck.equal(state.ticks, tick["ticks"], label <> " ticks")

    if state.phase == 1,
      do: DragonPhaseCheck.equal(state.charge, tick["charge"], label <> " charge")

    for {key, actual} <- [
          {"position", state.flight.position},
          {"velocity", state.flight.velocity},
          {"yaw", state.flight.yaw},
          {"turn", state.flight.turn}
        ],
        do: DragonPhaseCheck.equal(actual, tick[key], label <> " " <> key)

    DragonPhaseCheck.equal(Flight.boxes(state.flight), tick["parts"], label <> " parts")

    effects =
      for effect <- state.effects,
          match?({:fireball, _, _}, effect) or match?({:flame, _}, effect),
          do: effect

    DragonPhaseCheck.equal(length(effects), length(tick["effects"]), label <> " effects")

    for {effect, expected} <- Enum.zip(effects, tick["effects"]) do
      case effect do
        {:fireball, position, direction} ->
          true = expected["kind"] == "fireball"
          DragonPhaseCheck.equal(position, expected["position"], label <> " fireball position")
          DragonPhaseCheck.equal(direction, expected["direction"], label <> " fireball direction")

        {:flame, position} ->
          true =
            expected["kind"] == "flame" and expected["radius"] == 5.0 and
              expected["duration"] == 200

          DragonPhaseCheck.equal(position, expected["position"], label <> " flame position")
      end
    end

    DragonPhaseCheck.equal(:end_flame in state.effects, tick["end_flame"], label <> " end flame")

    for {:health, value} <- state.effects,
        do: DragonPhaseCheck.equal(value, tick["health"], label <> " health")

    state
  end)
end

IO.puts(
  "PASS: #{length(raw["cases"])} native dragon phase sequences, #{Enum.sum(Enum.map(raw["cases"], &length(&1["ticks"])))} ticks, paths, random, fireballs and breath"
)
