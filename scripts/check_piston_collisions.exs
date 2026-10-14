alias Valimc.Physics.{
  BlockEntityContext,
  BlockShapes,
  Box,
  Collision,
  CollisionContext,
  PistonSnapshot,
  Shape
}

[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()

directions = %{
  "down" => :down,
  "up" => :up,
  "north" => :north,
  "south" => :south,
  "west" => :west,
  "east" => :east,
  "none" => nil
}

axes = %{"x" => :x, "y" => :y, "z" => :z}

for c <- cases do
  f = c["context"]

  context =
    CollisionContext.with_piston_movement(
      CollisionContext.empty(),
      Map.fetch!(directions, f["exclusion"])
    )

  block_entity =
    case f["kind"] do
      "absent" ->
        BlockEntityContext.absent()

      "other" ->
        BlockEntityContext.other()

      "piston" ->
        PistonSnapshot.new(
          f["moved"],
          Map.fetch!(directions, f["direction"]),
          f["extending"],
          f["source"],
          f["progress"]
        )
        |> BlockEntityContext.piston()
    end

  pos = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  {:ok, shape} = BlockShapes.fetch(c["state"], pos, context, block_entity)

  if shape != Shape.from_facts!(c["geometry"]),
    do: raise("Native piston differs: #{inspect(c)} actual #{inspect(shape)}")

  world = Shape.move(shape, pos)

  for q <- c["queries"] do
    value =
      Collision.clip(
        Map.fetch!(axes, q["axis"]),
        Box.new(List.to_tuple(q["box"])),
        [world],
        q["delta"]
      )

    if Base.encode16(<<value::float-64>>, case: :lower) != q["result_bits"],
      do: raise("Native piston clipping differs: #{inspect(c)}")
  end
end

IO.puts("PASS: #{length(cases)} native piston snapshots and #{length(cases) * 6} exact clips.")
