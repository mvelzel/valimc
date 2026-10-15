alias Valimc.Physics.ClimbBlocks
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
true = length(cases) == ClimbBlocks.count()

for c <- cases do
  {:ok, actual} = ClimbBlocks.fetch(c["id"])
  expected = Map.new(c["properties"], fn {k, v} -> {String.to_existing_atom(k), v} end)
  if actual != expected, do: raise("Native climb facts mismatch #{inspect(c)} #{inspect(actual)}")
end

IO.puts("PASS: all #{length(cases)} native climb block facts.")
