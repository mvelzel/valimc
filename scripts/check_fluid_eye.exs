alias Valimc.World.View
alias Valimc.Physics.{BlockScan, Kernel}
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

  frame = View.of(Map.merge(states, supplied))
  {:ok, actual} = Kernel.eyes(frame, box, List.to_tuple(c["eye"]))

  for key <- [:water, :lava] do
    if actual[key] != c[Atom.to_string(key)],
      do: raise("Native fluid eye mismatch #{inspect(c)} #{inspect(actual)}")
  end
end

IO.puts("PASS: #{length(cases)} native eye contacts using the existing bounded body frame.")
