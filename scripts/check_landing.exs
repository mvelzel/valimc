alias Valimc.Living.Landing
alias Valimc.Data.BlockFacts
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
coverage = MapSet.new(cases, &{&1["id"], &1["shift"]})

unless MapSet.size(coverage) == 2 * BlockFacts.count(),
  do: raise("Incomplete landing state/shift coverage")

for c <- cases do
  {:ok, actual} = Landing.call(c["id"], c["distance"], c["shift"])

  unless Landing.holds_y?(c["id"]) == c["holds_y"],
    do: raise("Native legacy supporting-block rule differs #{c["id"]}")

  encoded =
    if actual,
      do: Map.new(actual, fn {key, value} -> {Atom.to_string(key), value} end)

  encoded =
    if encoded, do: Map.update!(encoded, "source", &Atom.to_string/1)

  unless encoded == c["call"], do: raise("Native landing mismatch #{inspect({c, encoded})}")
end

IO.puts(
  "PASS: #{length(cases)} native landing calls across #{BlockFacts.count()} states and both shift inputs."
)
