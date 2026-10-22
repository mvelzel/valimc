alias Valimc.Native
alias Valimc.Physics.Kernel
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

  exempt =
    fixture["changing_dimension"] or fixture["impulse"] or mode in [:creative, :spectator]

  {:ok, wrongly} =
    Native.physics_player_parity(
      :moved_wrongly,
      {floats.(fixture["requested"]), floats.(fixture["moved"]), exempt}
    )

  queried = not (fixture["no_physics"] or (wrongly and fixture["old_clear"]))
  if queried != fixture["queried_new"], do: raise("Native branch differs: #{index}")

  new_collision =
    Native.physics_parity_new_collision(
      floats.(fixture["old_box"]),
      Enum.map(fixture["new_colliders"], &Kernel.shape/1)
    )

  {:ok, rejected} =
    Native.physics_player_parity(
      :rejected,
      {fixture["no_physics"], wrongly, fixture["old_clear"], new_collision}
    )

  if rejected != fixture["rejected"], do: raise("Native movement decision differs: #{index}")
end

IO.puts(
  "PASS: #{length(cases)} post-move decisions (kernel new-collision test) match the actual native packet handler"
)
