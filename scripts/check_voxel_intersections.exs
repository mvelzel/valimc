alias Valimc.Physics.{Shape, VoxelOps}
[file] = System.argv()
data = file |> File.read!() |> JSON.decode!()
shapes = data["shapes"] |> Enum.map(&Shape.from_world_facts!/1) |> List.to_tuple()

for c <- data["boxes"] do
  actual = VoxelOps.world_box(List.to_tuple(c["bounds"]))
  if actual != elem(shapes, c["shape"]), do: raise("Native world box differs: #{inspect(c)}")
end

for [left, right, expected] <- data["pairs"] do
  actual = VoxelOps.intersects?(elem(shapes, left), elem(shapes, right))

  if actual != expected,
    do:
      raise(
        "Native intersection differs: #{left}/#{right}, expected #{expected}, actual #{actual}"
      )
end

IO.puts(
  "PASS: #{length(data["pairs"])} native intersections / #{length(data["boxes"])} world boxes."
)
