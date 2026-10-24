alias Valimc.Data.{Blocks, PlayerPose}
alias Valimc.Physics.Kernel
alias Valimc.Player.{Displacement, Input, Motion}
[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 1440, do: raise("Incomplete native player piston fixtures")

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

point = fn list -> list |> Enum.map(double) |> List.to_tuple() end

air =
  Map.new([0, 127], fn origin ->
    cells =
      for x <- (origin - 8)..(origin + 8), y <- 58..76, z <- -8..8, into: %{}, do: {{x, y, z}, 0}

    {origin, cells}
  end)

velocity_only =
  Enum.reduce(rows, 0, fn row, count ->
    true = row["simulates"]
    false = row["authoritative"]
    pos = [origin, _, _] = row["pos"]
    pos = List.to_tuple(pos)
    at = {x, y, z} = point.(row["start"])

    player = %{
      x: x,
      y: y,
      z: z,
      input: %Input{shared_flags: if(row["crouch"], do: 2, else: 0)},
      motion: %Motion{on_ground: row["ground"], velocity: {0.17, -0.11, 0.23}}
    }

    {:ok, %{box: {x0, y0, _, x1, y1, _}}} =
      PlayerPose.geometry(if(row["crouch"], do: :crouching, else: :standing), at)

    input = Displacement.input(player, {(x1 - x0) / 2, y1 - y0})

    states =
      Enum.reduce(row["cells"], air[origin], fn [a, b, c, state], acc ->
        Map.put(acc, {a, b, c}, state)
      end)

    moving =
      {Blocks.default_state(String.replace_prefix(row["material"], "minecraft:", "")),
       row["face"], row["extending"], false, 0.0, 0.0, 0, 0}

    state = states[pos]

    {:ok, [{position, velocity, ground, pushed}]} =
      Kernel.pistons(
        Valimc.World.View.of(states),
        [{pos, moving, 0.5, state, false}],
        [input],
        nil,
        false
      )

    actual = {position, velocity, ground}
    expected = {point.(row["position"]), point.(row["velocity"]), row["after_ground"]}

    unless actual == expected,
      do:
        raise(
          "Player piston #{row["material"]} face #{row["face"]} extending #{row["extending"]} crouch #{row["crouch"]}: #{inspect(actual)} != native #{inspect(expected)}"
        )

    if not pushed and velocity != elem(input, 2), do: count + 1, else: count
  end)

unless velocity_only > 0, do: raise("Missing velocity-only slime impulses")

IO.puts(
  "PASS: 1440 native player piston phases, exact position/velocity/ground, with #{velocity_only} velocity-only impulses"
)
