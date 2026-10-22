Code.require_file("kernel_shapes.exs", __DIR__)
alias Check.KernelShapes
alias Valimc.Physics.CollisionContext
Valimc.Data.BlockFacts.install!()
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()

# The kernel has no block entities (VMC-077l): a moving piston without one is
# empty, as vanilla's is. Piston snapshots are not modelled.
checked = Enum.filter(cases, &(&1["context"]["kind"] in ["absent", "other"]))

for c <- checked do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  picked = KernelShapes.picked(c["state"], position, CollisionContext.empty())

  if not KernelShapes.same?(picked, c["geometry"]),
    do: raise("Native piston differs: #{inspect(c)}")

  unless KernelShapes.clips?([KernelShapes.collider(picked, position)], c["queries"]),
    do: raise("Native piston clipping differs: #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(checked)} native moving pistons without block entities and #{Enum.sum(Enum.map(checked, &length(&1["queries"])))} exact kernel clips (#{length(cases) - length(checked)} piston snapshots not modelled)."
)
