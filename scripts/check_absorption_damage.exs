alias Valimc.Living.Health
alias Valimc.Player.Food
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

f32 = fn amount ->
  <<value::float-32>> = <<amount::float-32>>
  value
end

for row <- rows do
  armored = f32.(row["amount"] * row["armor_factor"])
  defended = f32.(armored * row["magic_factor"])
  {:ok, next} = Health.spend_absorption(row["pool"], defended)
  {:ok, health} = Health.reduce(%Health{value: row["health"]}, next.damage)

  food =
    if next.damage > 0,
      do: Food.exhaust(%Food{}, row["food_cost"]),
      else: %Food{}

  unless row["armor_input"] == row["amount"] and row["magic_input"] == armored and
           next.pool == row["after_pool"] and next.damage == row["recorded_damage"] and
           health.value == row["after_health"] and food.exhaustion == row["exhaustion"] and
           row["events"] == if(next.damage > 0, do: 1, else: 0),
         do: raise("Native Player absorption damage differs #{inspect(row)}: #{inspect(next)}")
end

IO.puts(
  "PASS: #{length(rows)} native Player damage/Absorption/health/food transitions, controlled defense order and all source kinds; outer hurt/death/live owners excluded."
)
