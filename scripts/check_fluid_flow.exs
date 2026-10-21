alias Valimc.World.View
alias Valimc.Physics.{BlockScan, Kernel}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end
{:ok, plan} = BlockScan.plan({0.2, 0.0, 0.2, 0.8, 1.8, 0.8})
base = Map.new(plan, fn {p, _} -> {p, 0} end)

for c <- cases do
  supplied = Map.new(c["states"], &{List.to_tuple(&1["position"]), &1["state"]})
  frame = View.of(Map.merge(base, supplied))
  {:ok, actual} = Kernel.flow(frame, {0, 0, 0})

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
