alias Valimc.World.View
alias Valimc.Entity.ItemMotionState
alias Valimc.Physics.BlockScan
alias Valimc.Data.Box
alias Valimc.World.ItemStep
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
      no_gravity: row["no_gravity"],
      in_water: row["water"]
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
  [result] = ItemStep.run(frame, [before], nil, fn _, _ -> false end)
  expected = input.(row["after"])
  {:ok, travel} = result
  {x, y, z} = travel.position

  sensed = %{
    kind: :item,
    uuid: <<1::128>>,
    x: x,
    y: y,
    z: z,
    width: 0.25,
    height: 0.25,
    count: 3,
    pickup_delay: 0,
    in_water: travel.motion.in_water
  }

  self = %Valimc.AI.Self{
    x: x,
    y: y,
    z: z,
    width: 0.9,
    height: 0.6,
    world: %Valimc.AI.World{items: [sensed], read: fn p -> states[p] end}
  }

  allowed = Valimc.AI.Mobs.Dolphin.items(self) != []

  unless allowed == row["after"]["play_ready"],
    do: raise("Dolphin native item predicate mismatch #{index}")

  bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

  # The travel oracle leaves burning out (stage `item_burn` has it).
  exact =
    case result do
      {:ok, actual} ->
        actual = Map.drop(actual, [:dead, :on_fire])
        actual = %{actual | motion: %{actual.motion | health: 5, fire_ticks: 0}}

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
