alias Valimc.Physics.FluidMotion
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
fields = Map.keys(Map.from_struct(%FluidMotion{})) -- [:kind, :falling]
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

check = fn c ->
  initial = List.to_tuple(c["initial"])
  resolved = List.to_tuple(c["resolved"])

  facts =
    fields
    |> Map.new(&{&1, Map.fetch!(c, Atom.to_string(&1))})
    |> Map.merge(%{kind: String.to_existing_atom(c["kind"]), falling: elem(initial, 1) <= 0})
    |> then(&struct!(FluidMotion, &1))

  {:ok, result} = FluidMotion.prepare(resolved, facts)
  query = if c["escape_query"], do: List.to_tuple(c["escape_query"])

  unless (query == nil and result.escape_query == nil) or
           (query != nil and result.escape_query != nil and
              bits.(query) == bits.(result.escape_query)),
         do: raise("Native fluid escape query mismatch #{inspect(c)} #{inspect(result)}")

  actual = FluidMotion.finish(result, c["free"])
  expected = List.to_tuple(c["velocity"])

  unless bits.(actual) == bits.(expected),
    do: raise("Native fluid travel mismatch #{inspect(c)} #{inspect(actual)}")

  actual
end

Enum.each(data["cases"], check)

for trace <- data["traces"] do
  Enum.reduce(trace, nil, fn c, previous ->
    if previous != nil and bits.(previous) != bits.(List.to_tuple(c["initial"])),
      do: raise("Broken native fluid trace boundary")

    check.(c)
  end)
end

IO.puts("PASS: #{length(data["cases"])} native fluid travel cases and 3x200 transition traces.")
