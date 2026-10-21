alias Valimc.Physics.{BlockScan, Box, FluidMotion, PlayerPose, SwimSteering}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end

for c <- cases do
  {:ok, look} = SwimSteering.look_y(c["pitch"])

  if bits.(look) != bits.(c["look_y"]),
    do: raise("Native swim look mismatch #{inspect(c)} #{look}")

  {:ok, actual} =
    SwimSteering.step(
      List.to_tuple(c["initial"]),
      look,
      c["swimming"],
      c["jump"],
      c["above_fluid"],
      c["passenger"]
    )

  if Enum.map(Tuple.to_list(actual), bits) != Enum.map(c["velocity"], bits),
    do: raise("Native swim steering mismatch #{inspect(c)} #{inspect(actual)}")

  player = %{
    game_mode: Valimc.GameMode.new(:creative),
    motion: %Valimc.PlayerMotion{velocity: List.to_tuple(c["initial"]), swimming: c["swimming"]},
    input: %Valimc.PlayerInput{shared_flags: 8}
  }

  {:ok, standing} = PlayerPose.geometry(:standing, {0.5, 64.0, 0.5})

  {:ok, body} =
    PlayerPose.geometry(if(c["swimming"], do: :swimming, else: :standing), {0.5, 64.0, 0.5})

  {:ok, query} = Valimc.PlayerKinetics.query_box(standing.box, player)
  {:ok, plan} = BlockScan.plan(query, 1024)
  acquired = MapSet.new(plan, &elem(&1, 0))

  for kind <- [:water, :lava], shift <- [-0.061, 0.0, 0.061] do
    {vx, vy, vz} = List.to_tuple(c["initial"])

    {:ok, adjusted} =
      SwimSteering.step(
        {vx, vy + shift, vz},
        look,
        c["swimming"],
        c["jump"],
        c["above_fluid"],
        c["passenger"]
      )

    {:ok, result} =
      FluidMotion.prepare(adjusted, %FluidMotion{
        kind: kind,
        horizontal_collision: true,
        sprint: true,
        old_y: 64.0,
        new_y: 64.0 + elem(adjusted, 1)
      })

    moved = Box.move(body.box, adjusted)

    for box <- [Box.expand_towards(body.box, adjusted), Box.move(moved, result.escape_query)] do
      {:ok, dependencies} = BlockScan.plan(box)

      unless Enum.all?(dependencies, &MapSet.member?(acquired, elem(&1, 0))),
        do: raise("Swim movement/escape outside acquired frame #{inspect(c)} #{inspect(box)}")
    end
  end
end

IO.puts(
  "PASS: #{length(cases)} native swim steering/look vectors and bounded movement/escape frame coverage."
)
