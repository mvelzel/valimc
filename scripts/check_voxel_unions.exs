alias Valimc.Physics.{Box, Collision, Shape, VoxelOps}
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
axes = %{"x" => :x, "y" => :y, "z" => :z}

for c <- cases do
  result =
    case c["operation"] do
      "box" -> VoxelOps.box(List.to_tuple(c["bounds"]))
      "optimize" -> VoxelOps.optimize(Shape.from_facts!(c["left"]))
      "union" -> VoxelOps.union(Shape.from_facts!(c["left"]), Shape.from_facts!(c["right"]))
    end

  if result != Shape.from_facts!(c["result"]),
    do: raise("Native voxel operation differs: #{inspect(c)} actual #{inspect(result)}")

  for q <- c["queries"] do
    value =
      Collision.clip(
        Map.fetch!(axes, q["axis"]),
        Box.new(List.to_tuple(q["box"])),
        [result],
        q["delta"]
      )

    if Base.encode16(<<value::float-64>>, case: :lower) != q["result_bits"],
      do: raise("Native voxel operation clipping differs: #{inspect(c)}")
  end
end

IO.puts("PASS: #{length(cases)} native voxel operations and #{length(cases) * 36} exact clips.")
