alias Valimc.Physics.{BlockCollisions.Frame, BlockEntityContext, BlockScan, FluidFlow}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end
{:ok, plan} = BlockScan.plan({0.2, 0.0, 0.2, 0.8, 1.8, 0.8})
base = Map.new(plan, fn {p, _} -> {p, 0} end)
entities = Map.new(base, fn {p, _} -> {p, BlockEntityContext.absent()} end)

for c <- cases do
  supplied = Map.new(c["states"], &{List.to_tuple(&1["position"]), &1["state"]})
  frame = %Frame{states: Map.merge(base, supplied), fences: %{}, entities: entities}
  {:ok, actual} = FluidFlow.sample(frame, {0, 0, 0})

  unless bits.(actual) == bits.(List.to_tuple(c["flow"])),
    do: raise("Native flow mismatch #{inspect(c)} #{inspect(actual)}")

  for p <- c["queries"] do
    unless Map.has_key?(base, List.to_tuple(p)),
      do: raise("Native flow query outside existing frame")
  end
end

IO.puts(
  "PASS: #{length(cases)} native fluid flow vectors and existing-frame dependency coverage."
)
