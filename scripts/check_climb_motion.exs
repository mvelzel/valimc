alias Valimc.Physics.{BlockScan, Box, ClimbMotion, PlayerPose}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end

check = fn actual, expected ->
  Enum.map(Tuple.to_list(actual), bits) == Enum.map(expected, bits)
end

for c <- cases do
  {:ok, before} =
    ClimbMotion.prepare(List.to_tuple(c["initial"]), c["climbing"], c["shift"], c["scaffolding"])

  unless check.(before.velocity, c["requested"]),
    do: raise("Native climb clamp mismatch #{inspect(c)} #{inspect(before)}")

  if if(before.reset_fall, do: 0.0, else: 5.0) != c["fall_distance"],
    do: raise("Native climb fall mismatch #{inspect(c)}")

  {:ok, actual} =
    ClimbMotion.finish(
      List.to_tuple(c["resolved"]),
      c["climbing"],
      c["horizontal_collision"],
      c["jump"]
    )

  unless check.(actual, c["velocity"]),
    do: raise("Native climb boost mismatch #{inspect(c)} #{inspect(actual)}")

  # Climbing shrinks the pre-collision velocity hull. Its moved feet/below
  # observations must still fit the existing frame; the boost moves next tick.
  for pose <- [:standing, :crouching, :swimming], y <- [64.01, 64.2, 64.99] do
    point = {0.5, y, 0.5}
    {:ok, standing} = PlayerPose.geometry(:standing, point)
    {:ok, body} = PlayerPose.geometry(pose, point)

    player = %{
      game_mode: Valimc.GameMode.new(:creative),
      motion: %Valimc.PlayerMotion{velocity: List.to_tuple(c["initial"])},
      input: %Valimc.PlayerInput{}
    }

    {:ok, query} = Valimc.PlayerKinetics.query_box(standing.box, player)
    {:ok, plan} = BlockScan.plan(query, 1024)
    acquired = MapSet.new(plan, &elem(&1, 0))
    {:ok, sweep} = BlockScan.plan(Box.expand_towards(body.box, before.velocity))
    {vx, vy, vz} = before.velocity
    feet = {floor(0.5 + vx), floor(y + vy), floor(0.5 + vz)}
    {x, fy, z} = feet
    dependencies = [feet, {x, fy - 1, z} | Enum.map(sweep, &elem(&1, 0))]

    unless Enum.all?(dependencies, &MapSet.member?(acquired, &1)),
      do: raise("Climb movement/contact outside acquired frame #{inspect(c)} #{pose} #{y}")
  end
end

IO.puts(
  "PASS: #{length(cases)} native climb clamps/boost/fall resets and bounded movement/contact frames."
)
