alias Valimc.Physics.{BlockShapes, Box, Collision, Shape}
[file] = System.argv()
native = file |> File.read!() |> JSON.decode!()
axes = %{"x" => :x, "y" => :y, "z" => :z}

for c <- native["queries"] do
  shapes =
    Enum.zip_with(c["shapes"], c["offsets"], fn id, offset ->
      {:ok, shape} = BlockShapes.fetch(id)
      Shape.move(shape, List.to_tuple(offset))
    end)

  box = Box.new(List.to_tuple(c["box"]))
  axis = Map.fetch!(axes, c["axis"])

  result =
    if c["raw"],
      do: Shape.collide(hd(shapes), axis, box, c["delta"]),
      else: Collision.clip(axis, box, shapes, c["delta"])

  bits = Base.encode16(<<result::float-64>>, case: :lower)

  if bits != c["result_bits"],
    do: raise("Native clipping differs: #{inspect(c)}; Elixir #{inspect(result)} #{bits}")
end

for c <- native["intersections"] do
  a = Box.new(List.to_tuple(c["a"]))
  b = Box.new(List.to_tuple(c["b"]))
  if Box.intersects?(a, b) != c["intersects"], do: raise("Native box intersection differs")
end

IO.puts(
  "PASS: #{length(native["queries"])} bit-exact native clipping results and #{length(native["intersections"])} box intersections."
)
