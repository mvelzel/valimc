Code.require_file("kernel_shapes.exs", __DIR__)
alias Check.KernelShapes
Valimc.Registry.BlockFacts.install!()
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
powder_snow = Valimc.Registry.Blocks.default_state("powder_snow")

for c <- cases do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  picked = KernelShapes.picked(powder_snow, position, KernelShapes.context(c["context"]))

  if not KernelShapes.same?(picked, c["geometry"]),
    do: raise("Native powder snow differs: #{inspect(c)}")

  unless KernelShapes.clips?([KernelShapes.collider(picked, position)], c["queries"]),
    do: raise("Native powder snow clipping differs: #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(cases)} native powder snow contexts and #{Enum.sum(Enum.map(cases, &length(&1["queries"])))} exact kernel clipping queries."
)
