alias Valimc.Native
alias Valimc.Physics.{Kernel, MovementValidation}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
floats = fn values -> values |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

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

  new_collision =
    Native.physics_parity_new_collision(
      floats.(fixture["old_box"]),
      Enum.map(fixture["new_colliders"], &Kernel.shape/1)
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
  "PASS: #{length(cases)} post-move decisions (kernel new-collision test) match the actual native packet handler"
)
