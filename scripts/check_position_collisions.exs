alias Valimc.Physics.{BlockOffset, BlockShapes, Box, Collision, Shape}
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()
axes = %{"x" => :x, "y" => :y, "z" => :z}
bits = fn value -> Base.encode16(<<value::float-64>>, case: :lower) end

for c <- cases do
  position = c["position"] |> Enum.map(&trunc/1) |> List.to_tuple()
  {:ok, shape} = BlockShapes.fetch(c["state"], position)
  native = Shape.from_facts!(c["geometry"])
  if shape != native, do: raise("Position geometry differs: #{inspect(c)}")
  limit = c["limit"]
  offset = BlockOffset.horizontal(position, limit) |> Tuple.to_list()

  unless Enum.zip_with(offset, c["offset"], &(bits.(&1) == bits.(&2))) |> Enum.all?(),
    do: raise("Position offset differs: #{inspect(c)}")

  world_shape = Shape.move(shape, position)

  for q <- c["queries"] do
    result =
      Collision.clip(
        Map.fetch!(axes, q["axis"]),
        Box.new(List.to_tuple(q["box"])),
        [world_shape],
        q["delta"]
      )

    if bits.(result) != q["result_bits"], do: raise("Position clipping differs: #{inspect(c)}")
  end
end

IO.puts(
  "PASS: #{length(cases)} native position geometry/offset cases and #{Enum.sum(Enum.map(cases, &length(&1["queries"])))} exact clipping queries."
)
