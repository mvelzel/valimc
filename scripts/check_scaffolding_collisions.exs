Code.require_file("kernel_shapes.exs", __DIR__)
alias Check.KernelShapes
alias Valimc.Physics.CollisionContext
Valimc.Data.BlockFacts.install!()
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()

for c <- cases do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  context = KernelShapes.context(c["context"])
  picked = KernelShapes.picked(c["state"], position, context)

  if not KernelShapes.same?(picked, c["geometry"]),
    do: raise("Native scaffolding differs: #{inspect(c)}")

  y = elem(position, 1)

  unless CollisionContext.above?(context, 1.0, y, true) == c["above_full"] and
           CollisionContext.above?(context, 0.0, y, true) == c["above_below"] and
           CollisionContext.above?(context, 1.0, y, false) == c["above_false_default"],
         do: raise("Native collision context differs: #{inspect(c)}")

  unless KernelShapes.clips?([KernelShapes.collider(picked, position)], c["queries"]),
    do: raise("Native scaffolding clipping differs: #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(cases)} native scaffolding contexts and #{Enum.sum(Enum.map(cases, &length(&1["queries"])))} exact kernel clipping queries."
)
