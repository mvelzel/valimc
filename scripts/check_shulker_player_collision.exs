alias Valimc.Entity.Body
alias Valimc.Player.{Kinetics, GameMode, Abilities, Input}
alias Valimc.Physics.Kernel
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 840, do: raise("Incomplete player/shulker collision fixtures")
Valimc.Data.BlockFacts.install!()

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

point = fn list -> list |> Enum.map(double) |> List.to_tuple() end

float = fn n ->
  <<v::float-32>> = <<n::signed-32>>
  v
end

states = for x <- -8..8, y <- 54..74, z <- -8..8, into: %{}, do: {{x, y, z}, 0}
view = Valimc.World.View.of(states)

for row <- cases do
  {:ok, body} = Body.new("minecraft:shulker")
  body = %{body | data: %{body.data | attach_face: row["face"], peek_amount: float.(row["peek"])}}
  body = if row["dead"], do: put_in(body.mob.living.health.value, 0.0), else: body

  boxes =
    case Valimc.AI.Mobs.Shulker.collider(body, {0.5, 64.0, 0.5}) do
      nil -> []
      box -> [box]
    end

  {x, y, z} = point.(row["position"])
  {dx, dy, dz} = point.(row["motion"])

  player = %{
    x: x,
    y: y,
    z: z,
    pose: :standing,
    game_mode: GameMode.new(:creative),
    abilities: Abilities.for_mode(:creative),
    input: Input.loaded(%Input{})
  }

  target = {x + dx, y + dy, z + dz}
  {:ok, query} = Kinetics.player_query(player, %{x: x + dx, y: y + dy, z: z + dz})

  {:ok, result} =
    Valimc.Native.physics_player_move(
      Kernel.native(view, query),
      Kinetics.player(player),
      target,
      0,
      nil,
      boxes
    )

  want = {point.(row["actual"]), row["accepted"]}
  got = {result.moved, result.accepted}

  if got != want,
    do:
      raise(
        "Shulker #{row["face"]} #{row["peek"]} dead #{row["dead"]} at #{inspect({x, y, z})}: #{inspect(got)} != native #{inspect(want)}"
      )
end

IO.puts(
  "PASS: 840 native player displacements and server admissions across living/dead shulkers, all six faces and partial/full lids"
)
