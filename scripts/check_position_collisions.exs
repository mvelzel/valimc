Code.require_file("kernel_shapes.exs", __DIR__)
alias Check.KernelShapes
alias Valimc.Physics.CollisionContext
Valimc.Registry.BlockFacts.install!()
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
bits = fn value -> Base.encode16(<<value::float-64>>, case: :lower) end

for c <- cases do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  picked = KernelShapes.picked(c["state"], position, CollisionContext.empty())

  if not KernelShapes.same?(picked, c["geometry"]),
    do: raise("Position geometry differs: #{inspect(c)}")

  offset = picked |> elem(1) |> Kernel.||({0.0, 0.0, 0.0}) |> Tuple.to_list()

  unless Enum.zip_with(offset, c["offset"], &(bits.(&1) == bits.(&2))) |> Enum.all?(),
    do: raise("Position offset differs: #{inspect(c)}")

  unless KernelShapes.clips?([KernelShapes.collider(picked, position)], c["queries"]),
    do: raise("Position clipping differs: #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(cases)} native position geometry/offset cases and #{Enum.sum(Enum.map(cases, &length(&1["queries"])))} exact kernel clipping queries."
)
