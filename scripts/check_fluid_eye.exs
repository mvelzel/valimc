alias Valimc.Physics.{BlockCollisions.Frame, BlockScan, FluidContact}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()

for c <- cases do
  box = List.to_tuple(c["box"])
  {:ok, plan} = BlockScan.plan(box)
  states = Map.new(plan, fn {p, _} -> {p, 0} end)

  supplied =
    Map.new(
      c["states"],
      &{&1["position"] |> Enum.map(fn n -> trunc(n) end) |> List.to_tuple(), &1["state"]}
    )

  frame = %Frame{states: Map.merge(states, supplied), fences: %{}, entities: %{}}
  {:ok, actual} = FluidContact.eyes(frame, box, List.to_tuple(c["eye"]))

  for key <- [:water, :lava] do
    if actual[key] != c[Atom.to_string(key)],
      do: raise("Native fluid eye mismatch #{inspect(c)} #{inspect(actual)}")
  end
end

IO.puts("PASS: #{length(cases)} native eye contacts using the existing bounded body frame.")
