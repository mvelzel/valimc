alias Valimc.World.View
alias Valimc.Physics.{BlockScan, Kernel}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

for c <- cases do
  box = List.to_tuple(c["box"])
  {:ok, plan} = BlockScan.plan(box)
  base = Map.new(plan, fn {p, _} -> {p, 0} end)
  states = Map.merge(base, Map.new(c["states"], &{List.to_tuple(&1["position"]), &1["state"]}))

  frame = View.of(states)

  {:ok, actual} =
    Kernel.current(frame, box, List.to_tuple(c["initial"]), c["pushed"], c["fast_lava"], :player)

  unless bits.(actual.velocity) == bits.(List.to_tuple(c["velocity"])),
    do: raise("Native player current mismatch #{inspect(c)} #{inspect(actual)}")

  for kind <- [:water, :lava] do
    unless <<actual.depths[kind]::float-64>> == <<c[Atom.to_string(kind)]::float-64>>,
      do: raise("Native current depth mismatch #{inspect(c)} #{inspect(actual)}")
  end

  for p <- c["queries"] do
    unless Map.has_key?(base, List.to_tuple(p)),
      do: raise("Native current query outside geometry frame")
  end
end

IO.puts(
  "PASS: #{length(cases)} native player currents/depths and existing-frame dependency coverage."
)
