alias Valimc.Entity.{Body, MobFacts, Store}
alias Valimc.Physics.Kernel
[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 480, do: raise("Incomplete dolphin breathing fixtures")
MobFacts.install!()

point = fn hexes ->
  hexes
  |> Enum.map(fn hex ->
    <<v::float-64>> = Base.decode16!(hex, case: :lower)
    v
  end)
  |> List.to_tuple()
end

air = for x <- -7..7, y <- 59..71, z <- -7..7, into: %{}, do: {{x, y, z}, 0}

for row <- rows do
  at = point.(row["start"])
  {:ok, body} = Body.new("minecraft:dolphin")
  motion = %{body.mob.motion | pre_move: row["yaw"] * 1.0, strafe: 0.4, up: 0.2, forward: 0.7}

  body = %{
    body
    | no_gravity: true,
      yaw: row["yaw"] * 1.0,
      velocity: point.(row["velocity"]),
      on_ground: row["ground"],
      mob: %{body.mob | motion: motion}
  }

  {input, _} = Valimc.Native.mob_oracle_body_kernel(Store.body_record(body, <<1::128>>, at))

  states =
    Enum.reduce(row["cells"], air, fn [x, y, z, state], acc -> Map.put(acc, {x, y, z}, state) end)

  boxes = Enum.map(row["boxes"], &List.to_tuple/1)
  # Fixed rows provide the actual neighboring solid entity boxes.
  others =
    for {x0, y0, z0, x1, _y1, z1} <- boxes,
        do: %{
          input
          | position: {(x0 + x1) / 2, y0, (z0 + z1) / 2},
            velocity: {0.0, 0.0, 0.0},
            fixed: true
        }

  colliders = boxes |> Enum.with_index(1) |> Enum.map(fn {box, i} -> {i, box} end)
  ticker = Kernel.mobs_begin(Valimc.World.View.of(states), [input | others], [], nil, colliders)
  {:ok, actual} = Kernel.mob_goal_position(ticker, 0, input)
  {:ok, again} = Kernel.mob_goal_position(ticker, 0, input)
  expected = point.(row["position"])

  unless actual == expected and actual == again,
    do:
      raise(
        "Dolphin breathing #{inspect(Map.drop(row, ["cells"]))}: #{inspect(actual)} != native #{inspect(expected)}"
      )

  # Observations must not change any stored velocity or consume a tick.
  [velocity | _] = Kernel.mobs_finish(ticker)
  unless velocity == input.velocity, do: raise("Goal observation changed the ticker")
end

IO.puts(
  "PASS: 480 actual native breathing-goal moves against blocks and solid entities, with repeatable observations and unchanged ticker velocity"
)
