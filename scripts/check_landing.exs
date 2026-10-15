alias Valimc.Physics.LandingBlocks
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
coverage = MapSet.new(cases, &{&1["id"], &1["shift"]})

unless MapSet.size(coverage) == 2 * LandingBlocks.state_count(),
  do: raise("Incomplete landing state/shift coverage")

for c <- cases do
  {:ok, actual} = LandingBlocks.call(c["id"], c["distance"], c["shift"])

  encoded =
    if actual,
      do: Map.new(actual, fn {key, value} -> {Atom.to_string(key), value} end)

  encoded =
    if encoded, do: Map.update!(encoded, "source", &Atom.to_string/1)

  unless encoded == c["call"], do: raise("Native landing mismatch #{inspect({c, encoded})}")
end

IO.puts(
  "PASS: #{length(cases)} native landing calls across #{LandingBlocks.state_count()} states and both shift inputs."
)
