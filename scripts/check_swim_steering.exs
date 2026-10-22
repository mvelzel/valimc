alias Valimc.Native
alias Valimc.Physics.{BlockScan, Kernel}
alias Valimc.Data.{Box, PlayerPose}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end
vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

fluid_motion =
  for key <- ~w(falling on_ground dolphins_grace climbable shallow)a,
      into: %{kind: :water, water_efficiency: 0.0, gravity: 0.08},
      do: {key, key == :falling}

for c <- cases do
  {:ok, look} = Native.physics_player_parity(:look_y, c["pitch"] * 1.0)

  if bits.(look) != bits.(c["look_y"]),
    do: raise("Native swim look mismatch #{inspect(c)} #{look}")

  {:ok, actual} =
    Native.physics_player_parity(
      :swim_steer,
      {vec.(c["initial"]), look, c["swimming"], c["jump"], c["above_fluid"], c["passenger"]}
    )

  if Enum.map(Tuple.to_list(actual), bits) != Enum.map(c["velocity"], bits),
    do: raise("Native swim steering mismatch #{inspect(c)} #{inspect(actual)}")

  player = %{
    game_mode: Valimc.Player.GameMode.new(:creative),
    motion: %Valimc.Player.Motion{velocity: vec.(c["initial"]), swimming: c["swimming"]},
    input: %Valimc.Player.Input{shared_flags: 8}
  }

  {:ok, standing} = PlayerPose.geometry(:standing, {0.5, 64.0, 0.5})

  {:ok, body} =
    PlayerPose.geometry(if(c["swimming"], do: :swimming, else: :standing), {0.5, 64.0, 0.5})

  {:ok, query} =
    Native.physics_player_parity(:kinetic_query, {Kernel.player(player), standing.box, false})

  {:ok, plan} = BlockScan.plan(query, 1024)
  acquired = MapSet.new(plan, &elem(&1, 0))

  for kind <- [:water, :lava], shift <- [-0.061, 0.0, 0.061] do
    {vx, vy, vz} = vec.(c["initial"])

    {:ok, adjusted} =
      Native.physics_player_parity(
        :swim_steer,
        {{vx, vy + shift, vz}, look, c["swimming"], c["jump"], c["above_fluid"], c["passenger"]}
      )

    {:ok, {_velocity, escape}} =
      Native.physics_player_parity(
        :fluid_motion,
        {adjusted,
         Map.merge(fluid_motion, %{
           kind: kind,
           horizontal_collision: true,
           sprint: true,
           old_y: 64.0,
           new_y: 64.0 + elem(adjusted, 1)
         })}
      )

    moved = Box.move(body.box, adjusted)

    for box <- [Box.expand_towards(body.box, adjusted), Box.move(moved, escape)] do
      {:ok, dependencies} = BlockScan.plan(box)

      unless Enum.all?(dependencies, &MapSet.member?(acquired, elem(&1, 0))),
        do: raise("Swim movement/escape outside acquired frame #{inspect(c)} #{inspect(box)}")
    end
  end
end

IO.puts(
  "PASS: #{length(cases)} native swim steering/look vectors and bounded movement/escape frame coverage."
)
