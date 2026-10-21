alias Valimc.World.View
alias Valimc.{ItemMotionState}
alias Valimc.Physics.{BlockScan, Box, ItemStep}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
unless length(cases) == 12960, do: raise("Incomplete native travel traces")

# The cells an item tick may read: its body grown by the current, gravity and
# buoyancy envelope (the scan adds its halo).
query = fn %{position: {x, y, z}, motion: %{velocity: {vx, vy, vz}}} ->
  {x - 0.125, y, z - 0.125, x + 0.125, y + 0.25, z + 0.125}
  |> Box.expand_towards({min(0, vx - 0.022), min(0, vy - 0.062), min(0, vz - 0.022)})
  |> Box.expand_towards({max(0, vx + 0.022), max(0, vy + 0.023), max(0, vz + 0.022)})
end

input = fn row ->
  %{
    position: List.to_tuple(row["position"]),
    motion: %ItemMotionState{
      velocity: List.to_tuple(row["velocity"]),
      age: row["age"],
      pickup_delay: row["pickup_delay"],
      on_ground: row["on_ground"],
      no_gravity: row["no_gravity"]
    }
  }
end

for {row, index} <- Enum.with_index(cases) do
  before = input.(row["before"])
  {:ok, plan} = BlockScan.plan(query.(before), 1024)
  base = Map.new(plan, fn {p, _} -> {p, 0} end)

  for c <- row["states"],
      do:
        unless(Map.has_key?(base, List.to_tuple(Enum.map(c["position"], &round/1))),
          do: raise("Native dependency outside frame #{index}: #{inspect(c)}")
        )

  states =
    Map.merge(
      base,
      Map.new(
        row["states"],
        &{List.to_tuple(Enum.map(&1["position"], fn n -> round(n) end)), &1["state"]}
      )
    )

  frame = View.of(states)
  [result] = ItemStep.run(frame, [before], nil)
  expected = input.(row["after"])
  bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

  exact =
    case result do
      {:ok, actual} ->
        actual == expected and bits.(actual.position) == bits.(expected.position) and
          bits.(actual.motion.velocity) == bits.(expected.motion.velocity)

      _ ->
        false
    end

  unless exact,
    do:
      raise(
        "Travel mismatch #{index}: #{inspect(row)}\n#{inspect(result)} != #{inspect(expected)}"
      )
end

IO.puts("PASS: #{length(cases)} actual native item travel steps and frame dependency coverage")
