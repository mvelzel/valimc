alias Valimc.{HungerEffect, PlayerFood, StatusEffect}
[path, timing_path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  {:ok, {:exhaust, amount}} = HungerEffect.request([{-1, row["amplifier"], false, true, true}])
  food = %PlayerFood{exhaustion: row["before"]}
  next = if row["invulnerable"], do: food, else: PlayerFood.exhaust(food, amount)

  unless next.exhaustion == row["after"] and row["applied"],
    do: raise("Native Hunger exhaustion differs #{inspect(row)}: #{inspect(next)}")
end

timing = timing_path |> File.read!() |> JSON.decode!()

for row <- timing do
  effect = [{row["ticks"], row["amplifier"], false, true, true}]
  {:ok, request} = HungerEffect.request(effect)

  exhaustion =
    case request do
      :none -> 0.0
      {:exhaust, amount} -> amount
    end

  {:ok, [{ticks, _, _, _, _}], remains, false} = StatusEffect.tick(effect)

  unless exhaustion == row["exhaustion"] and ticks == row["next_ticks"] and
           remains == row["remains"],
         do: raise("Native Hunger instance timing differs #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(rows)} native Hunger callback/ability/exhaustion compositions and#{length(timing)} native instance tick/duration contexts; live ownership/food spending excluded."
)
