[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
if length(cases) != Valimc.Physics.FluidBlocks.count(), do: raise("Incomplete dense fluid cases")

Enum.each(Enum.with_index(cases), fn {c, id} ->
  if c["id"] != id, do: raise("Non-contiguous native fluid cases")
  {:ok, result} = Valimc.Physics.FluidBlocks.fetch(id)

  unless Valimc.Physics.FluidBlocks.after_removal(id) == c["replacement"],
    do: raise("Native base-removal state mismatch #{id}")

  expected = c["properties"]

  if result.kind != elem({:empty, :water, :lava}, expected["kind"]) or
       Map.drop(result, [:kind]) !=
         Map.new(Map.delete(expected, "kind"), fn {k, v} -> {String.to_existing_atom(k), v} end),
     do: raise("Native fluid mismatch #{id}: #{inspect(result)} #{inspect(expected)}")
end)

IO.puts(
  "PASS: all #{length(cases)} compiled block fluid lookups match dense native observations."
)
