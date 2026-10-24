alias Valimc.Entity.{Body, MobMotion}
alias Valimc.Physics.Kernel
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 1512, do: raise("Incomplete mob/shulker collision fixtures")

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
  {:ok, shell} = Body.new("minecraft:shulker")

  shell = %{
    shell
    | data: %{shell.data | attach_face: row["face"], peek_amount: float.(row["peek"])}
  }

  shell = if row["dead"], do: put_in(shell.mob.living.health.value, 0.0), else: shell
  at = {0.5, 64.0, 0.5}
  box = Valimc.AI.Mobs.Shulker.collider(shell, at)
  {:ok, mover} = Body.new(row["type"])
  mover = %{mover | no_gravity: true, velocity: point.(row["motion"])}
  input = MobMotion.kernel(mover.type, point.(row["position"]), mover)
  shell_input = MobMotion.kernel(shell.type, at, shell)
  ticker = Kernel.mobs_begin(view, [input, shell_input], [], nil, [{1, box}])
  :ok = Kernel.mob_collider(ticker, 1, at, box)
  {{:ok, %{mob: %{position: actual}}}, _} = Kernel.mob_step(ticker, 0, input)
  _ = Kernel.mobs_finish(ticker)
  expected = point.(row["actual"])

  if actual != expected,
    do:
      raise(
        "#{row["type"]} shulker #{row["face"]} peek #{row["peek"]} dead #{row["dead"]}: #{inspect(actual)} != native #{inspect(expected)}"
      )
end

IO.puts(
  "PASS: 1512 native mob displacements across living/dead shulkers, three mob sizes, all six faces and partial/full lids"
)
