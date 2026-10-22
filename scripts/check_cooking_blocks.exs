[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Blocks.CookingBlocks

true =
  raw["version"] == "26.3" and raw["data_version"] == 5023 and
    raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["cases"]) == 864 and length(raw["states"]) == 24
kinds = {:furnace, :smoker, :blast_furnace}
yaw = %{2 => 180.0, 3 => 0.0, 4 => 90.0, 5 => 270.0}

for row <- raw["cases"] do
  {:ok, actual} = CookingBlocks.placement(elem(kinds, row["kind"]), yaw[row["heading"]])
  true = actual == row["result"]
end

for row <- raw["states"], do: true = CookingBlocks.kind(row["state"]) == elem(kinds, row["kind"])

IO.puts(
  "PASS: all864 native processing-block candidates and24 state kinds; shared heading arithmetic retains prior native yaw boundaries. Lifecycle/mining admission pending."
)
