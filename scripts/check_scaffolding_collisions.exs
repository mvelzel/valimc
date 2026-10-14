alias Valimc.Physics.{BlockShapes, Box, Collision, CollisionContext, Shape}
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
axes = %{"x" => :x, "y" => :y, "z" => :z}

for c <- cases do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()

  context =
    if c["context"]["kind"] == "empty",
      do: CollisionContext.empty(),
      else:
        CollisionContext.entity(
          c["context"]["bottom"],
          c["context"]["descending"],
          c["context"]["placement"]
        )

  {:ok, shape} = BlockShapes.fetch(c["state"], position, context)

  if shape != Shape.from_facts!(c["geometry"]),
    do: raise("Native scaffolding differs: #{inspect(c)}")

  y = elem(position, 1)

  unless CollisionContext.above?(context, 1.0, y, true) == c["above_full"] and
           CollisionContext.above?(context, 0.0, y, true) == c["above_below"] and
           CollisionContext.above?(context, 1.0, y, false) == c["above_false_default"],
         do: raise("Native collision context differs: #{inspect(c)}")

  world_shape = Shape.move(shape, position)

  for q <- c["queries"] do
    result =
      Collision.clip(
        Map.fetch!(axes, q["axis"]),
        Box.new(List.to_tuple(q["box"])),
        [world_shape],
        q["delta"]
      )

    if Base.encode16(<<result::float-64>>, case: :lower) != q["result_bits"],
      do: raise("Native scaffolding clipping differs: #{inspect(c)}")
  end
end

IO.puts(
  "PASS: #{length(cases)} native scaffolding contexts and #{Enum.sum(Enum.map(cases, &length(&1["queries"])))} exact clipping queries."
)
