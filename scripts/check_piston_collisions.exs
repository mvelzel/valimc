Code.require_file("kernel_shapes.exs", __DIR__)
alias Check.KernelShapes
alias Valimc.Native
alias Valimc.Physics.CollisionContext
Valimc.Data.BlockFacts.install!()
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()

# A moving piston without its block entity (or with another one) is empty;
# with one, the kernel builds its shape from the block entity (VMC-048b),
# vanilla's grid and clips bit for bit.
{plain, moving} = Enum.split_with(cases, &(&1["context"]["kind"] in ["absent", "other"]))

for c <- plain do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  picked = KernelShapes.picked(c["state"], position, CollisionContext.empty())

  if not KernelShapes.same?(picked, c["geometry"]),
    do: raise("Native piston differs: #{inspect(c)}")

  unless KernelShapes.clips?([KernelShapes.collider(picked, position)], c["queries"]),
    do: raise("Native piston clipping differs: #{inspect(c)}")
end

directions = Map.new(Enum.with_index(~w(down up north south west east)))

for c <- moving do
  f = c["context"]
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  noclip = Map.get(directions, f["exclusion"], -1)

  picked =
    Native.physics_parity_moving(
      position,
      {f["moved"], directions[f["direction"]], f["extending"], f["source"], f["progress"] * 1.0},
      noclip
    )

  unless KernelShapes.same?(picked, c["geometry"]),
    do: raise("Moving piston differs: #{inspect(c)} got #{inspect(picked)}")

  unless KernelShapes.clips?([KernelShapes.collider(picked, position)], c["queries"]),
    do: raise("Moving piston clipping differs: #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(plain)} moving pistons without block entities and #{length(moving)} with them, #{Enum.sum(Enum.map(cases, &length(&1["queries"])))} exact kernel clips."
)
