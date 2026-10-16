alias Valimc.{HungerEffect, PlayerFood, PlayerHealth}
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  before = row["before"]

  food = %PlayerFood{
    level: before["level"],
    saturation: before["saturation"],
    exhaustion: before["exhaustion"],
    timer: before["timer"]
  }

  {:ok, {:exhaust, amount}} = HungerEffect.request([{1, row["amplifier"], false, true, true}])

  {next, action} =
    PlayerFood.tick(
      PlayerFood.exhaust(food, amount),
      %PlayerHealth{value: row["health"]},
      row["difficulty"],
      row["regeneration"]
    )

  expected = row["after"]

  unless next.level == expected["level"] and next.saturation == expected["saturation"] and
           next.exhaustion == expected["exhaustion"] and next.timer == expected["timer"] and
           action.heal == row["heal"] and action.damage == row["damage"],
         do:
           raise(
             "Native Hunger/food composition differs #{inspect(row)}: #{inspect({next, action})}"
           )
end

IO.puts(
  "PASS: #{length(rows)} native Hunger-before-food states/health requests; owner death/replication excluded."
)
