# The flight steps, part boxes, graph and paths are the native dragon's
# (`Native.dragon_oracle_flight/5`, `dragon_oracle_paths/3`). A flight is
# the term the dragon's record keeps (a map tagged `Valimc.Entity.Dragon.Flight`).
[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()
Valimc.Entity.MobFacts.install!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

graph =
  for row <- Valimc.Data.Facts.read!("registry/dragon_facts.json")["graph"],
      do: row |> Enum.map(&trunc/1) |> List.to_tuple()

defmodule DragonFlightCheck do
  def equal(actual, expected, label) when is_tuple(actual),
    do: equal(Tuple.to_list(actual), expected, label)

  def equal(actual, expected, label) when is_list(actual) do
    true = length(actual) == length(expected)
    Enum.zip(actual, expected) |> Enum.each(fn {a, b} -> equal(a, b, label) end)
  end

  def equal(actual, expected, label) do
    unless abs(actual - expected) <= 1.0e-9,
      do: raise("#{label}: #{inspect(actual)} differs from #{inspect(expected)}")
  end
end

for row <- raw["flights"] do
  initial = row["initial"]

  state = %{
    __struct__: Valimc.Entity.Dragon.Flight,
    position: List.to_tuple(initial["position"]),
    velocity: List.to_tuple(initial["velocity"]),
    yaw: initial["yaw"],
    turn: initial["turn"],
    history: nil,
    parts: Tuple.duplicate({0.0, 0.0, 0.0}, 8)
  }

  Enum.with_index(row["ticks"])
  |> Enum.reduce(state, fn {tick, index}, state ->
    target = tick["target"] && tick["target"] |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()

    {state, boxes} =
      Valimc.Native.dragon_oracle_flight(
        state,
        target,
        row["phase"],
        tick["wall"] == true,
        tick["no_ai"] == true
      )

    label = "phase #{row["phase"]} scene #{row["scene"]} tick #{index}"

    for {field, key} <- [
          {:position, "position"},
          {:velocity, "velocity"},
          {:yaw, "yaw"},
          {:turn, "turn"}
        ],
        do: DragonFlightCheck.equal(Map.fetch!(state, field), tick[key], label <> " " <> key)

    DragonFlightCheck.equal(boxes, tick["parts"], label <> " parts")
    state
  end)
end

for row <- raw["paths"] do
  height = fn x, z ->
    case row["terrain"] do
      0 -> 0
      1 -> 90
      2 -> 65 + Integer.mod(x * 13 + z * 7, 48)
    end
  end

  crystals = if row["crystals"] < 0, do: nil, else: row["crystals"]
  final = fn c -> if c["finish"], do: {3, 77, -2} end
  scene = %{height: for({x, _, z, _} <- graph, do: {x, z, height.(x, z)})}

  {closest, found} =
    Valimc.Native.dragon_oracle_paths(
      scene,
      for(
        c <- row["closest"],
        do: {List.to_tuple(Enum.map(c["position"], &(&1 * 1.0))), crystals}
      ),
      for(c <- row["paths"], do: {c["start"], c["end"], crystals, final.(c)})
    )

  for {c, node} <- Enum.zip(row["closest"], closest), do: true = node == c["node"]

  for {c, result} <- Enum.zip(row["paths"], found) do
    expected = c["nodes"] && Enum.map(c["nodes"], &List.to_tuple/1)

    unless result == expected,
      do: raise("dragon path differs: #{inspect({row["terrain"], crystals, c, result})}")
  end
end

IO.puts(
  "PASS: #{length(raw["flights"]) * 80} dragon flight ticks with eight part boxes, 45 closest nodes and #{length(raw["paths"]) * 24 * 24 * 2} native paths, every one the native dragon's"
)
