alias Valimc.Physics.FluidBoundaries
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
if length(cases) != FluidBoundaries.count(), do: raise("Incomplete native fluid boundaries")

for {c, id} <- Enum.with_index(cases) do
  if c["id"] != id, do: raise("Non-contiguous native boundary cases")
  {:ok, actual} = FluidBoundaries.fetch(id)

  expected =
    Map.new(c["properties"], fn {k, v} ->
      {String.to_existing_atom(k), if(k == "context", do: String.to_existing_atom(v), else: v)}
    end)

  if actual != expected, do: raise("Native fluid boundary mismatch #{id}")
end

IO.puts("PASS: all #{length(cases)} native fluid boundary observations.")
