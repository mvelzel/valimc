alias Valimc.Physics.{MovementValidation, Shape}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for {fixture, index} <- Enum.with_index(cases) do
  mode =
    case fixture["mode"] do
      "survival" -> :survival
      "creative" -> :creative
      "adventure" -> :adventure
      "spectator" -> :spectator
    end

  {:ok, wrongly} =
    MovementValidation.wrongly?(
      List.to_tuple(fixture["requested"]),
      List.to_tuple(fixture["moved"]),
      mode,
      fixture["changing_dimension"],
      fixture["impulse"]
    )

  queried = not (fixture["no_physics"] or (wrongly and fixture["old_clear"]))
  if queried != fixture["queried_new"], do: raise("Native branch differs: #{index}")

  {:ok, new_collision} =
    MovementValidation.new_collision?(
      List.to_tuple(fixture["old_box"]),
      Enum.map(fixture["new_colliders"], &Shape.from_world_facts!/1)
    )

  {:ok, rejected} =
    MovementValidation.collision_rejected?(
      fixture["no_physics"],
      wrongly,
      fixture["old_clear"],
      new_collision
    )

  if rejected != fixture["rejected"], do: raise("Native movement decision differs: #{index}")
end

IO.puts(
  "PASS: #{length(cases)} Elixir post-move decisions match the actual native packet handler"
)
