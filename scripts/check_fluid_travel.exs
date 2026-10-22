alias Valimc.{Native, PlayerInput, PlayerMotion}
alias Valimc.Physics.{BlockScan, Box, Kernel, PlayerPose}
[path] = System.argv()
data = path |> File.read!() |> :json.decode()

fields =
  ~w(on_ground sprint dolphins_grace water_efficiency horizontal_collision climbable shallow old_y new_y)a

bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end
float = fn v -> if is_number(v), do: v * 1.0, else: v end
vec = fn l -> l |> Enum.map(float) |> List.to_tuple() end

check = fn c ->
  initial = vec.(c["initial"])
  resolved = vec.(c["resolved"])

  {:ok, gravity} =
    Native.physics_player_parity(
      :gravity,
      {c["gravity"] * 1.0, elem(initial, 1), c["slow_falling"]}
    )

  facts =
    fields
    |> Map.new(&{&1, float.(Map.fetch!(c, Atom.to_string(&1)))})
    |> Map.merge(%{
      kind: String.to_existing_atom(c["kind"]),
      falling: elem(initial, 1) <= 0,
      gravity: gravity
    })

  {:ok, {velocity, escape}} = Native.physics_player_parity(:fluid_motion, {resolved, facts})
  query = if c["escape_query"], do: List.to_tuple(c["escape_query"])

  unless (query == nil and escape == nil) or
           (query != nil and escape != nil and bits.(query) == bits.(escape)),
         do:
           raise(
             "Native fluid escape query mismatch #{inspect(c)} #{inspect({velocity, escape})}"
           )

  {:ok, actual} = Native.physics_player_parity(:fluid_finish, {velocity, escape, c["free"]})
  expected = List.to_tuple(c["velocity"])

  unless bits.(actual) == bits.(expected),
    do: raise("Native fluid travel mismatch #{inspect(c)} #{inspect(actual)}")

  # The native escape also samples a prospective translated body. Prove the
  # live acquired frame contains every collision candidate for these fixtures.
  if abs(c["old_y"]) <= 1_000_000 do
    {:ok, geometry} = PlayerPose.geometry(:standing, {0.5, c["old_y"], 0.5})

    player = %{
      motion: %PlayerMotion{velocity: initial},
      input: %PlayerInput{},
      yaw: 0.0,
      game_mode: Valimc.GameMode.new(:creative)
    }

    {:ok, envelope} =
      Native.physics_player_parity(:kinetic_query, {Kernel.player(player), geometry.box, false})

    {:ok, acquired} = BlockScan.plan(envelope, 1024)
    positions = MapSet.new(acquired, &elem(&1, 0))
    {:ok, movement} = BlockScan.plan(Box.expand_towards(geometry.box, initial))

    escape =
      if query do
        moved =
          Box.move(geometry.box, {elem(initial, 0), c["new_y"] - c["old_y"], elem(initial, 2)})

        {:ok, escaped} = BlockScan.plan(Box.move(moved, query))
        escaped
      else
        []
      end

    unless Enum.all?(movement ++ escape, &MapSet.member?(positions, elem(&1, 0))),
      do: raise("Native fluid movement/escape outside acquired frame #{inspect(c)}")
  end

  actual
end

Enum.each(data["cases"], check)

for trace <- data["traces"] do
  Enum.reduce(trace, nil, fn c, previous ->
    if previous != nil and bits.(previous) != bits.(List.to_tuple(c["initial"])),
      do: raise("Broken native fluid trace boundary")

    check.(c)
  end)
end

IO.puts(
  "PASS: #{length(data["cases"])} native fluid travel cases, 3x200 transition traces and live frame coverage within player Y bounds."
)
