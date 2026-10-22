alias Valimc.Native
alias Valimc.Physics.Kernel
[path] = System.argv()
data = path |> File.read!() |> :json.decode()

keys =
  ~w(x_collision z_collision vertical_collision below suppress_bounce block_suppresses_bounce
     entity_bounciness block_bounciness gravity air_drag)a

floats = fn values -> values |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

bits = fn tuple ->
  for n <- Tuple.to_list(tuple) do
    <<value::unsigned-64>> = <<n::float-64>>
    Integer.to_string(value, 16) |> String.downcase()
  end
end

Enum.each(data["cases"], fn c ->
  facts = Map.new(keys, &{&1, Map.fetch!(c, Atom.to_string(&1))})
  result = Kernel.respond(List.to_tuple(c["movement"]), c["moved_y"], facts)

  actual = bits.(result.velocity)

  if actual != c["velocity_bits"] or result.bounced != c["bounced"],
    do: raise("Native collision response mismatch #{inspect(c)}: #{inspect(result)}")
end)

Enum.each(data["traces"], fn trace ->
  colliders =
    Enum.map(trace["obstacles"], &{Native.physics_parity_box_shape(floats.(&1)), nil, nil})

  Enum.reduce(
    trace["steps"],
    {List.to_tuple(trace["initial"]), floats.(trace["box"]), false},
    fn s, {v, b, previous_ground} ->
      {x, y, z} = v
      # Native moveRelative adds its zero-input vector before collision work.
      v = {x + 0.0, y + 0.0, z + 0.0}
      moved = Native.physics_parity_move(colliders, b, v)
      vertical = elem(moved, 1) != elem(v, 1)
      ground = vertical and elem(v, 1) < 0

      resolved =
        Kernel.respond(v, elem(moved, 1), %{
          x_collision: abs(elem(moved, 0) - elem(v, 0)) >= 9.999999747378752e-6,
          z_collision: abs(elem(moved, 2) - elem(v, 2)) >= 9.999999747378752e-6,
          vertical_collision: vertical,
          below: ground,
          block_bounciness: trace["block_bounciness"]
        })

      {:ok, next} =
        Native.physics_player_parity(
          :air_step,
          {resolved.velocity,
           %{
             on_ground: previous_ground,
             friction: trace["friction"] * 1.0,
             friction_modifier: 1.0,
             air_drag_modifier: 1.0,
             gravity: 0.08,
             levitation: nil,
             discard_friction: false,
             omnidirectional: false
           }}
        )

      {dx, dy, dz} = moved
      {x0, y0, z0, x1, y1, z1} = b
      body = {x0 + dx, y0 + dy, z0 + dz, x1 + dx, y1 + dy, z1 + dz}

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
