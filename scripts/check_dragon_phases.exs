# Each scene's phases set, strafe and tick as the native dragon's
# (`Native.dragon_oracle_phases/3`) over a hand-built env: its graph's
# heights, podium, crystals, players, sight and ground. The phases are the
# term the dragon's record keeps (maps tagged `Valimc.Entity.Dragon.Phases` and
# `.Flight`).
[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()
Valimc.Entity.MobFacts.install!()

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

  # The phases term of a fresh dragon flying from `position` at yaw 25.
  def phases(position, random) do
    flight = %{
      __struct__: Valimc.Entity.Dragon.Flight,
      position: position,
      velocity: {0.0, 0.0, 0.0},
      yaw: 25.0,
      turn: 0.0,
      history: nil,
      parts: Tuple.duplicate({0.0, 0.0, 0.0}, 8)
    }

    %{
      __struct__: Valimc.Entity.Dragon.Phases,
      phase: 10,
      flight: flight,
      random: random,
      target: nil,
      leaving: nil,
      path: nil,
      clockwise: %{0 => false, 1 => false},
      ticks: 0,
      flames: 0,
      attack: nil,
      charge: 0,
      first: true,
      flame_live: false,
      head_yaw: 25.0,
      pitch: 0.0,
      effects: []
    }
  end
end

for row <- raw["cases"] do
  podium = {0, 90, 0}
  crystals = if(row["crystals"] < 0, do: nil, else: row["crystals"])

  all_players =
    Enum.map(
      row["players"],
      &%{id: &1["id"], position: List.to_tuple(&1["position"]), height: &1["height"]}
    )

  # The scene: every graph height 90, the podium, crystals and players, its
  # sight, its ground below y 70 (below 0 in scene 3).
  scene = fn players, collision ->
    %{
      height: 90,
      podium: podium,
      crystals: crystals,
      players: players,
      sees: row["scene"] != 3,
      floor: if(row["scene"] == 3, do: 0, else: 70),
      ground: Valimc.Data.Blocks.default_state("end_stone"),
      collision: collision == true
    }
  end

  native = fn state, op, players, collision ->
    {state, boxes} = Valimc.Native.dragon_oracle_phases(state, op, scene.(players, collision))
    Process.put(:dragon_boxes, boxes)
    state
  end

  random = Valimc.Data.JavaRandom.new(4519 + row["scene"])
  start = DragonPhaseCheck.phases(List.to_tuple(row["position"]), random)
  state = native.(start, {:set, row["start_phase"]}, all_players, false)
  player = List.first(all_players)

  state =
    cond do
      state.phase == 1 and player != nil -> native.(state, {:strafe, player}, all_players, false)
      state.phase == 8 and player -> %{state | target: player.position}
      true -> state
    end

  Enum.with_index(row["ticks"])
  |> Enum.reduce(state, fn {tick, index}, state ->
    players =
      if tick["player_present"],
        do: Enum.map(all_players, &%{&1 | position: List.to_tuple(tick["player_position"])}),
        else: []

    state = native.(state, {:tick, false}, players, tick["collision"])

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

    DragonPhaseCheck.equal(Process.get(:dragon_boxes), tick["parts"], label <> " parts")

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
  "PASS: #{length(raw["cases"])} native dragon phase sequences, #{Enum.sum(Enum.map(raw["cases"], &length(&1["ticks"])))} ticks, paths, random, fireballs and breath, every tick the native dragon's"
)
