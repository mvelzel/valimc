alias Valimc.World.View
alias Valimc.Entity.{ExperienceOrbs, ItemMotionState}
alias Valimc.Physics.BlockScan
alias Valimc.Data.Box
alias Valimc.World.ItemStep
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
travel = data["travel"]
unless length(travel) == 12960, do: raise("Incomplete native orb travel")

unless length(data["merges"]) == 600 and length(data["awards"]) == 144,
  do: raise("Incomplete native orb merges or awards")

# The cells an orb tick may read: its body grown by the current, gravity, pull
# and lava jump envelope (the scan adds its halo).
query = fn %{position: {x, y, z}, motion: %{velocity: {vx, vy, vz}}} ->
  {x - 0.25, y, z - 0.25, x + 0.25, y + 0.5, z + 0.25}
  |> Box.expand_towards({min(0, vx - 0.33), min(0, vy - 0.33), min(0, vz - 0.33)})
  |> Box.expand_towards({max(0, vx + 0.33), max(0, vy + 0.33), max(0, vz + 0.33)})
end

state = fn row ->
  %{
    position: List.to_tuple(row["position"]),
    motion: %ItemMotionState{
      velocity: List.to_tuple(row["velocity"]),
      on_ground: row["on_ground"]
    }
  }
end

bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end
cell = fn c -> List.to_tuple(Enum.map(c["position"], &round/1)) end

for {row, index} <- Enum.with_index(travel) do
  before = state.(row["before"])
  {:ok, plan} = BlockScan.plan(query.(before), 1024)
  base = Map.new(plan, fn {p, _} -> {p, 0} end)

  for c <- row["states"],
      do:
        unless(Map.has_key?(base, cell.(c)),
          do: raise("Native dependency outside frame #{index}: #{inspect(c)}")
        )

  frame = View.of(Map.merge(base, Map.new(row["states"], &{cell.(&1), &1["state"]})))
  target = if row["target"], do: List.to_tuple(row["target"])
  orb = Map.merge(before, %{target: target, draws: List.to_tuple(row["draws"])})
  [result] = ItemStep.run_orbs(frame, [orb], nil)
  expected = state.(row["after"])

  exact =
    case result do
      {:ok, actual} ->
        actual.position == expected.position and actual.motion == expected.motion and
          bits.(actual.position) == bits.(expected.position) and
          bits.(actual.motion.velocity) == bits.(expected.motion.velocity)

      _ ->
        false
    end

  unless exact,
    do: raise("Orb travel mismatch #{index}: #{inspect(row)}\n#{inspect(result)}")
end

for {row, index} <- Enum.with_index(data["merges"]) do
  before = row["before"]

  orbs =
    Map.new(before, fn o ->
      {o["id"],
       %{value: o["value"], count: o["count"], age: o["age"], at: List.to_tuple(o["position"])}}
    end)

  {merged, absorbed} = ExperienceOrbs.merge(orbs, Enum.map(before, & &1["id"]))

  for {o, a} <- Enum.zip(before, row["after"]) do
    actual =
      if o["id"] in absorbed,
        do: %{"removed" => true},
        else: %{
          "removed" => false,
          "count" => merged[o["id"]].count,
          "age" => merged[o["id"]].age
        }

    expected = if a["removed"], do: %{"removed" => true}, else: a

    unless actual == expected,
      do: raise("Orb merge mismatch #{index}: #{inspect(row)}\n#{inspect({merged, absorbed})}")
  end
end

for {row, index} <- Enum.with_index(data["awards"]) do
  {:ok, picks} = Agent.start_link(fn -> row["picks"] end)
  pick = fn -> Agent.get_and_update(picks, fn [p | rest] -> {p, rest} end) end
  actual = ExperienceOrbs.plan(row["amounts"], pick, row["base"])
  [] = Agent.get(picks, & &1)
  Agent.stop(picks)
  expected = Enum.map(row["orbs"], fn [_id, value, count] -> {value, count} end)

  unless actual == expected and
           Enum.map(row["orbs"], &hd/1) ==
             Enum.to_list(row["base"]..(row["base"] + length(expected) - 1)//1),
         do: raise("Orb award mismatch #{index}: #{inspect(row)}\n#{inspect(actual)}")
end

IO.puts(
  "PASS: #{length(travel)} actual native orb travel steps with frame dependency coverage, " <>
    "#{length(data["merges"])} merge scenes and #{length(data["awards"])} award spawn plans"
)
