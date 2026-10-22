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

IO.puts(
  "PASS: 288 isolated native chest contexts, 35,723 target fluids and #{length(raw["yaw"])} yaw boundaries; 55,584 observed neighbor contexts include unsupported double candidates. No runtime placement claim."
)
