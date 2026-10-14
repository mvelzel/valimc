alias Valimc.Physics.{BlockScan, Box}
[file] = System.argv()
facts = file |> File.read!() |> JSON.decode!()

for c <- facts["plans"] do
  {:ok, positions} = BlockScan.plan(c["box"] |> List.to_tuple() |> Box.new())
  actual = for {{x, y, z}, type} <- positions, do: [x, y, z, type]
  if actual != c["positions"], do: raise("Native block scan differs: #{inspect(c)}")
end

for [id | values] <- facts["eligibility"], {expected, type} <- Enum.with_index(values) do
  if BlockScan.eligible(id, type) != {:ok, expected},
    do: raise("Native block eligibility differs: #{id}/#{type}")
end

IO.puts(
  "PASS: #{length(facts["plans"])} native ordered scans and #{length(facts["eligibility"]) * 4} state boundary decisions."
)
