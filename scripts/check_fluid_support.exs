alias Valimc.Physics.{
  BlockCollisions.Frame,
  BlockEntityContext,
  FluidBoundaries,
  PistonSnapshot,
  Shape,
  VoxelOps
}

[path] = System.argv()
data = path |> File.read!() |> :json.decode()

for c <- data["grids"], {expected, direction} <- Enum.with_index(c["faces"]) do
  actual = VoxelOps.face_full?(Shape.from_facts!(c["geometry"]), direction)
  if actual != expected, do: raise("Native support grid mismatch #{direction} #{inspect(c)}")
end

for c <- data["contexts"] do
  entity =
    case c["kind"] do
      "shulker" ->
        BlockEntityContext.shulker(c["progress"], c["progress"], c["closed"])

      "piston" ->
        PistonSnapshot.new(
          c["moved"],
          String.to_existing_atom(c["direction"]),
          c["extending"],
          c["source"],
          c["progress"]
        )
        |> BlockEntityContext.piston()
    end

  p = {0, 64, 0}
  frame = %Frame{states: %{p => c["state"]}, entities: %{p => entity}, fences: %{}}

  for {expected, direction} <- Enum.with_index(c["faces"]) do
    {:ok, actual} = FluidBoundaries.sturdy?(frame, p, direction)

    if actual != expected,
      do: raise("Native contextual support mismatch #{direction} #{inspect(c)}")
  end
end

IO.puts(
  "PASS: #{length(data["grids"])} native support grids / #{length(data["contexts"])} block-entity face contexts."
)
