alias Valimc.Physics.{BlockEntityContext, BlockShapes, Box, Collision, CollisionContext, Shape}
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
axes = %{"x" => :x, "y" => :y, "z" => :z}

for c <- cases do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  facts = c["context"]

  context =
    case facts["kind"] do
      "absent" -> BlockEntityContext.absent()
      "other" -> BlockEntityContext.other()
      "shulker" -> BlockEntityContext.shulker(facts["old"], facts["current"])
    end

  {:ok, shape} = BlockShapes.fetch(c["state"], position, CollisionContext.empty(), context)
  if shape != Shape.from_facts!(c["geometry"]), do: raise("Native shulker differs: #{inspect(c)}")
  world = Shape.move(shape, position)

  for q <- c["queries"] do
    result =
      Collision.clip(
        Map.fetch!(axes, q["axis"]),
        Box.new(List.to_tuple(q["box"])),
        [world],
        q["delta"]
      )

    if Base.encode16(<<result::float-64>>, case: :lower) != q["result_bits"],
      do: raise("Native shulker clipping differs: #{inspect(c)}")
  end
end

IO.puts("PASS: #{length(cases)} native shulker snapshots and #{length(cases) * 6} exact clips.")
