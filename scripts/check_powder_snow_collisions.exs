alias Valimc.Physics.{BlockShapes, Box, Collision, CollisionContext, Shape}
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
axes = %{"x" => :x, "y" => :y, "z" => :z}

for c <- cases do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  facts = c["context"]

  context =
    if facts["kind"] == "empty" do
      CollisionContext.empty()
    else
      geometry = CollisionContext.entity(facts["bottom"], facts["descending"], facts["placement"])

      if facts["entity_present"],
        do:
          CollisionContext.with_entity(
            geometry,
            facts["fall_distance"],
            facts["falling_block"],
            facts["walkable"]
          ),
        else: geometry
    end

  {:ok, shape} = BlockShapes.fetch(30519, position, context)

  if shape != Shape.from_facts!(c["geometry"]),
    do: raise("Native powder snow differs: #{inspect(c)}")

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
      do: raise("Native powder-snow clipping differs: #{inspect(c)}")
  end
end

IO.puts(
  "PASS: #{length(cases)} native powder-snow contexts and #{length(cases) * 6} exact clips."
)
