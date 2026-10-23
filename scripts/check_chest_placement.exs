[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Blocks.ChestPlacement

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = raw["neighbor_worlds"] == 193 and length(raw["neighbors"]) == 193
true = length(raw["cases"]) == 55_584 and raw["double_candidates"] == 960
true = length(raw["fluid_states"]) == 35_723
yaw = %{3 => 0.0, 4 => 90.0, 2 => 180.0, 5 => 270.0}
for [angle, heading] <- raw["yaw"], do: {:ok, ^heading} = ChestPlacement.horizontal(angle)

for row <- raw["cases"], row["neighbor"] == 0 do
  {:ok, state} = ChestPlacement.single_state(yaw[row["horizontal"]], row["target"])
  true = state == row["result"]
end

for [target, expected] <- raw["fluid_states"],
    do: {:ok, ^expected} = ChestPlacement.single_state(180.0, target)

# The live shared placement rules also choose the joined halves, from the
# same candidate contexts the oracle observed (targeting is a separate stage).
item = Valimc.Protocol.Data.item("chest")

neighbors =
  raw["neighbors"]
  |> Enum.with_index()
  |> Map.new(fn {rows, i} ->
    {i,
     Enum.map(rows, fn row ->
       [x, y, z] = row["position"]
       {x, y, z, row["state"]}
     end)}
  end)

prepared =
  for row <- raw["cases"] do
    request = %{
      position: {0, 0, 0},
      face: row["face"],
      cursor: {0.5, 0.5, 0.5},
      yaw: yaw[row["horizontal"]],
      pitch: 0.0,
      secondary: row["secondary"]
    }

    {:ok, %{values: values}} = Valimc.Blocks.Placement.target(item, 0, request)
    {item, values, {0, 0, 0}, [{0, 0, 0, row["target"]} | neighbors[row["neighbor"]]]}
  end

{:ok, results} = Valimc.Native.rules_placement_cases(Valimc.World.BlockRules.native(), prepared)

for {row, writes} <- Enum.zip(raw["cases"], results) do
  unless writes == [{0, 0, 0, row["result"]}],
    do: raise("chest candidate mismatch: #{inspect({row, writes})}")
end

IO.puts(
  "PASS: 55,584 native chest placement candidates including 960 joined halves, all target fluids and #{length(raw["yaw"])} yaw boundaries"
)
