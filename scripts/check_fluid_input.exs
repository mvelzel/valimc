alias Valimc.Physics.FluidControls
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
keys = Map.keys(Map.from_struct(%FluidControls{}))
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

for c <- cases do
  f = struct!(FluidControls, Map.new(keys, &{&1, Map.fetch!(c, Atom.to_string(&1))}))
  {:ok, actual} = FluidControls.step(List.to_tuple(c["initial"]), f)

  unless bits.(actual.velocity) == bits.(List.to_tuple(c["velocity"])) and
           actual.ground_jump == c["ground_jump"],
         do: raise("Native fluid input mismatch #{inspect(c)} #{inspect(actual)}")
end

IO.puts("PASS: #{length(cases)} native fluid input/jump and normalized sink cases.")
