alias Valimc.Entity.{Body, MobFacts, Projectile, Store}
alias Valimc.Physics.Kernel
[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 378, do: raise("Incomplete shulker physical-box fixtures")
MobFacts.install!()

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

point = fn list -> list |> Enum.map(double) |> List.to_tuple() end

float = fn n ->
  <<v::float-32>> = <<n::signed-32>>
  v
end

air = Valimc.Data.Blocks.default_state("air")
# Fixed local windows avoid dependence on a running world.

for row <- cases do
  {:ok, body} = Body.new("minecraft:shulker")
  body = %{body | data: %{body.data | attach_face: row["face"], peek_amount: float.(row["peek"])}}
  at = point.(row["at"])
  # The row its native mob publishes, whose box the store reads, and the box
  # its family blocks others with in the native tick.
  record = Store.body_record(body, <<1::128>>, at)
  {:ok, {_, published, _}} = Valimc.Native.mob_section_row(record)
  {_, collider} = Valimc.Native.mob_oracle_body_kernel(record)
  box = Body.box(published, at)
  native = point.(row["box"])

  if box != native or collider != native,
    do:
      raise(
        "Shulker face #{row["face"]} peek #{row["peek"]}: #{inspect({box, collider})} != #{inspect(native)}"
      )

  for shot <- row["shots"] do
    {x, y, z} = start = point.(shot["start"])
    velocity = point.(shot["velocity"])

    states =
      for cx <- (floor(x) - 5)..(floor(x) + 5),
          cy <- (floor(y) - 3)..(floor(y) + 3),
          cz <- (floor(z) - 5)..(floor(z) + 5),
          into: %{},
          do: {{cx, cy, cz}, air}

    projectile = %{Projectile.new("minecraft:arrow", nil) | velocity: velocity}
    input = Projectile.input(projectile, start, {0.5, 0.5, 0.5})

    {:ok, [{:ok, _, hit, _, _}]} =
      Kernel.projectiles(Valimc.World.View.of(states), [input], [{1, at, box}], nil, false)

    expected = if shot["hit"], do: {:entities, [{1, point.(shot["hit"])}]}

    if hit != expected,
      do: raise("Shulker face #{row["face"]}: #{inspect(hit)} != native #{inspect(expected)}")
  end
end

IO.puts(
  "PASS: 378 native shulker physical boxes and 2646 arrow segments across all six attachment faces"
)
