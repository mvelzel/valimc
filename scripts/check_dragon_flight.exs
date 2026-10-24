alias Valimc.AI.Dragon.{Flight, Paths}

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

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

  state = %Flight{
    position: List.to_tuple(initial["position"]),
    velocity: List.to_tuple(initial["velocity"]),
    yaw: initial["yaw"],
    turn: initial["turn"]
  }

  Enum.with_index(row["ticks"])
  |> Enum.reduce(state, fn {tick, index}, state ->
    target = tick["target"] && List.to_tuple(tick["target"])
    state = Flight.step(state, target, row["phase"], tick["wall"], tick["no_ai"])
    label = "phase #{row["phase"]} scene #{row["scene"]} tick #{index}"

    for {field, key} <- [
          {:position, "position"},
          {:velocity, "velocity"},
          {:yaw, "yaw"},
          {:turn, "turn"}
        ],
        do: DragonFlightCheck.equal(Map.fetch!(state, field), tick[key], label <> " " <> key)

    DragonFlightCheck.equal(Flight.boxes(state), tick["parts"], label <> " parts")
    state
  end)
end

for row <- raw["paths"] do
  graph =
    Paths.graph(fn x, z ->
      case row["terrain"] do
        0 -> 0
        1 -> 90
        2 -> 65 + Integer.mod(x * 13 + z * 7, 48)
      end
    end)

  crystals = if row["crystals"] < 0, do: nil, else: row["crystals"]

  for c <- row["closest"],
      do: true = Paths.closest(graph, List.to_tuple(c["position"]), crystals) == c["node"]

  for c <- row["paths"] do
    final = if c["finish"], do: {3, 77, -2}
    result = Paths.find(graph, c["start"], c["end"], crystals, final)
    expected = c["nodes"] && Enum.map(c["nodes"], &List.to_tuple/1)

    unless result == expected,
      do: raise("dragon path differs: #{inspect({row["terrain"], crystals, c, result})}")
  end
end

IO.puts(
  "PASS: #{length(raw["flights"]) * 80} dragon flight ticks with eight part boxes, 45 closest nodes and #{length(raw["paths"]) * 24 * 24 * 2} native paths"
)
