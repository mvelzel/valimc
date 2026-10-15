alias Valimc.Physics.{AirMotion, Box, Collision, CollisionResponse, VoxelOps}
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
keys = Map.keys(%CollisionResponse{}) -- [:__struct__]

bits = fn tuple ->
  for n <- Tuple.to_list(tuple) do
    <<value::unsigned-64>> = <<n::float-64>>
    Integer.to_string(value, 16) |> String.downcase()
  end
end

Enum.each(data["cases"], fn c ->
  facts = struct!(CollisionResponse, Map.new(keys, &{&1, Map.fetch!(c, Atom.to_string(&1))}))
  {:ok, result} = CollisionResponse.step(List.to_tuple(c["movement"]), c["moved_y"], facts)

  actual = bits.(result.velocity)

  if actual != c["velocity_bits"] or result.bounced != c["bounced"],
    do: raise("Native collision response mismatch #{inspect(c)}: #{inspect(result)}")
end)

Enum.each(data["traces"], fn trace ->
  shapes = Enum.map(trace["obstacles"], &(List.to_tuple(&1) |> Box.new() |> VoxelOps.world_box()))

  Enum.reduce(
    trace["steps"],
    {List.to_tuple(trace["initial"]), List.to_tuple(trace["box"]), false},
    fn s, {v, b, previous_ground} ->
      {x, y, z} = v
      # Native moveRelative adds its zero-input vector before collision work.
      v = {x + 0.0, y + 0.0, z + 0.0}
      moved = Collision.move(b, shapes, v)
      vertical = elem(moved, 1) != elem(v, 1)
      ground = vertical and elem(v, 1) < 0

      {:ok, resolved} =
        CollisionResponse.step(v, elem(moved, 1), %CollisionResponse{
          x_collision: abs(elem(moved, 0) - elem(v, 0)) >= 9.999999747378752e-6,
          z_collision: abs(elem(moved, 2) - elem(v, 2)) >= 9.999999747378752e-6,
          vertical_collision: vertical,
          below: ground,
          block_bounciness: trace["block_bounciness"]
        })

      {:ok, next} =
        AirMotion.step(resolved.velocity, %AirMotion{
          on_ground: previous_ground,
          friction: trace["friction"]
        })

      body = Box.move(b, moved)

      if bits.(moved) != s["moved_bits"] or bits.(next) != s["velocity_bits"] or
           bits.(body) != bits.(List.to_tuple(s["box"])) or resolved.bounced != s["bounced"],
         do:
           raise(
             "Native accumulated collision/air trace mismatch #{inspect(s)}: #{inspect(next)}"
           )

      {next, body, ground}
    end
  )
end)

IO.puts(
  "PASS: #{length(data["cases"])} bit-exact native collision responses and bounce notifications; #{length(data["traces"])} accumulated 200-step collision/air traces."
)
