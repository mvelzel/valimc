Code.require_file("kernel_shapes.exs", __DIR__)
alias Check.KernelShapes
alias Valimc.Native
alias Valimc.Physics.{BlockScan, Kernel}
alias Valimc.Data.Box
import Bitwise, only: [band: 2, bsl: 2]
Valimc.Data.BlockFacts.install!()

[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
pos = fn values -> values |> Enum.map(&trunc/1) |> List.to_tuple() end

# The kernel has no block entities (VMC-077l): shulker boxes and moving
# pistons collide as vanilla's do without one. Snapshots are not modelled.
checked =
  Enum.reject(cases, fn c -> Enum.any?(c["entities"], &(&1["kind"] in ["shulker", "piston"])) end)

bits = fn {position, state, {axes, sizes, cells}} ->
  {position, state, Enum.map(axes, fn a -> Enum.map(a, &<<&1::float-64>>) end), sizes, cells}
end

for {c, index} <- Enum.with_index(checked) do
  states = Map.new(c["states"], &{pos.(&1["position"]), &1["state"]})
  box = c["box"] |> List.to_tuple() |> Box.new()
  {:ok, plan} = BlockScan.plan(box)

  view =
    Valimc.World.View.of(
      Map.new(plan, fn {p, _} -> {p, Map.get(states, p, c["default_state"])} end)
    )

  expected =
    Enum.map(c["colliders"], &{pos.(&1["position"]), &1["state"], Kernel.shape(&1["geometry"])})

  actual =
    Native.physics_parity_colliders(
      Kernel.native(view, box),
      box,
      Kernel.context(KernelShapes.context(c["context"]))
    )

  unless is_list(actual) and Enum.map(actual, bits) == Enum.map(expected, bits),
    do:
      raise(
        "Native block collection differs at #{index}: #{inspect(c)} actual #{inspect(actual)}"
      )

  for {position, state, {[xs, ys, zs], [nx, ny, nz], cells}} <- expected do
    boxes =
      for x <- 0..(nx - 1)//1,
          y <- 0..(ny - 1)//1,
          z <- 0..(nz - 1)//1,
          i = (x * ny + y) * nz + z,
          band(:binary.at(cells, div(i, 8)), bsl(1, rem(i, 8))) != 0 do
        {Enum.at(xs, x), Enum.at(ys, y), Enum.at(zs, z), Enum.at(xs, x + 1), Enum.at(ys, y + 1),
         Enum.at(zs, z + 1)}
      end

    unless Kernel.collision_boxes(state, position, KernelShapes.context(c["context"])) == boxes,
      do: raise("Production contextual collision cells differ at native case #{index}")
  end
end

IO.puts(
  "PASS: #{length(checked)} native ordered collider cases through the kernel (#{length(cases) - length(checked)} with block entity snapshots not modelled)."
)
