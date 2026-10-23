alias Valimc.World.View
alias Valimc.Entity.ItemMotionState
alias Valimc.Physics.BlockScan
alias Valimc.Data.Box
alias Valimc.World.ItemStep
[path] = System.argv()
rows = path |> File.read!() |> :json.decode()

# The cells a tick may read: the body grown by the current, gravity and jump
# envelope (the scan adds its halo).
query = fn kind, %{position: {x, y, z}, motion: %{velocity: {vx, vy, vz}}} ->
  half = if kind == "orb", do: 0.25, else: 0.125

  {x - half, y, z - half, x + half, y + 2 * half, z + half}
  |> Box.expand_towards({min(0, vx - 0.33), min(0, vy - 0.33), min(0, vz - 0.33)})
  |> Box.expand_towards({max(0, vx + 0.33), max(0, vy + 0.33), max(0, vz + 0.33)})
end

state = fn row ->
  %{
    position: List.to_tuple(row["position"]),
    motion: %ItemMotionState{
      velocity: List.to_tuple(row["velocity"]),
      on_ground: row["on_ground"],
      age: Map.get(row, "age", 0),
      pickup_delay: Map.get(row, "pickup_delay", 0),
      health: row["health"],
      fire_ticks: row["fire"]
    }
  }
end

bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end
cell = fn c -> List.to_tuple(Enum.map(c["position"], &round/1)) end

for {row, index} <- Enum.with_index(rows) do
  kind = row["kind"]
  before = state.(row["before"])
  {:ok, plan} = BlockScan.plan(query.(kind, before), 1024)
  base = Map.new(plan, fn {p, _} -> {p, 0} end)

  for c <- row["states"],
      do:
        unless(Map.has_key?(base, cell.(c)),
          do:
            raise(
              "Native dependency outside frame #{index}: #{inspect(c)} #{inspect(Map.delete(row, "states"))}"
            )
        )

  frame = View.of(Map.merge(base, Map.new(row["states"], &{cell.(&1), &1["state"]})))

  [result] =
    if kind == "orb",
      do: ItemStep.run_orbs(frame, [Map.put(before, :draws, List.to_tuple(row["draws"]))], nil),
      else: ItemStep.run(frame, [Map.put(before, :fire_immune, kind == "netherite")], nil)

  expected = state.(row["after"])

  # A removed entity's last move is never seen (vanilla's skips it); its
  # health and burning are.
  exact =
    case result do
      {:ok, %{dead: true} = actual} ->
        row["after"]["removed"] and actual.motion.health == expected.motion.health and
          actual.motion.fire_ticks == expected.motion.fire_ticks

      {:ok, actual} ->
        actual.dead == row["after"]["removed"] and actual.position == expected.position and
          actual.motion == expected.motion and
          bits.(actual.position) == bits.(expected.position) and
          bits.(actual.motion.velocity) == bits.(expected.motion.velocity)

      _ ->
        false
    end

  unless exact,
    do: raise("Burn mismatch #{index}: #{inspect(row)}\n#{inspect(result)}")
end

burned = rows |> Enum.filter(& &1["after"]["removed"]) |> Enum.map(&{&1["kind"], &1["layout"]})
put_out = Enum.count(rows, &(&1["before"]["fire"] > 0 and &1["after"]["fire"] == 0))

# Lava, fire, soul fire, cactus, fire then water, and burning on after fire
# each burn up stone and orbs; netherite only meets its end on a cactus.
unless MapSet.new(burned) ==
         MapSet.new([{"netherite", 3} | for(k <- ~w(stone orb), l <- 0..5, do: {k, l})]) and
         put_out >= 2,
       do: raise("Burning coverage: #{inspect(Enum.frequencies(burned))}, #{put_out} put out")

IO.puts(
  "PASS: #{length(rows)} native item and orb burning ticks, #{length(burned)} burned up, #{put_out} put out."
)
