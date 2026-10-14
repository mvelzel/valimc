alias Valimc.Physics.{Box, Collision, Shape}
[file] = System.argv()
data = file |> File.read!() |> JSON.decode!()
shapes = data["shapes"] |> Enum.map(&Shape.from_facts!/1) |> List.to_tuple()

for c <- data["cases"] do
  position = List.to_tuple(c["position"])
  colliders = Enum.map(c["shapes"], &Shape.move(elem(shapes, &1), position))
  box = c["box"] |> List.to_tuple() |> Box.new()
  requested = List.to_tuple(c["requested"])
  result = Collision.move(box, colliders, requested)
  bits = for value <- Tuple.to_list(result), do: Base.encode16(<<value::float-64>>, case: :lower)

  if bits != c["result_bits"],
    do: raise("Native movement differs: #{inspect(c)} actual #{inspect(result)}")
end

IO.puts(
  "PASS: #{length(data["cases"])} native movement vectors (all three exact result components)."
)
