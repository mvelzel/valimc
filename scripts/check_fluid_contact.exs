alias Valimc.World.View
alias Valimc.Physics.{BlockScan, Kernel}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end

Enum.each(cases, fn c ->
  box = List.to_tuple(c["box"])
  {:ok, plan} = BlockScan.plan(box)
  states = Map.new(plan, fn {p, _} -> {p, 0} end)
  supplied = Map.new(c["states"], &{List.to_tuple(&1["position"]), &1["state"]})
  frame = View.of(Map.merge(states, supplied))
  {:ok, actual} = Kernel.fluids(frame, box)

  for key <- [:water, :lava] do
    if bits.(actual[key]) != bits.(c[Atom.to_string(key)]),
      do: raise("Native fluid depth mismatch #{inspect(c)} #{inspect(actual)}")
  end

  # Every actual fluid cell also needs the cell above. The existing collision
  # scan already covers both, without expanding the bounded query envelope.
  {a, b, c0, d, e, f} = box

  body =
    for x <- floor(a + 0.001)..(ceil(d - 0.001) - 1),
        y <- floor(b + 0.001)..(ceil(e - 0.001) - 1),
        z <- floor(c0 + 0.001)..(ceil(f - 0.001) - 1),
        do: {x, y, z}

  for {x, y, z} = p <- body do
    unless Map.has_key?(states, p) and Map.has_key?(states, {x, y + 1, z}),
      do: raise("Fluid dependency outside geometry frame #{inspect(p)}")
  end
end)

IO.puts("PASS: #{length(cases)} native fluid depths and existing-frame dependency coverage.")
