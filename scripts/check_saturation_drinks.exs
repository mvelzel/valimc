alias Valimc.{InstantEffect, PlayerFood}
alias Valimc.Protocol.EffectTypes
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  food = %PlayerFood{
    level: row["level"],
    saturation: row["saturation"],
    exhaustion: 3.990000009536743,
    timer: 9
  }

  {:ok, {:eat, nutrition, saturation}} =
    InstantEffect.drink_request(EffectTypes.id("saturation"), row["amplifier"])

  next = PlayerFood.eat(food, nutrition, saturation)

  unless next.level == row["next_level"] and next.saturation == row["next_saturation"] and
           next.exhaustion == row["next_exhaustion"] and next.timer == row["next_timer"],
         do: raise("Native Saturation drink differs #{inspect(row)}: #{inspect(next)}")
end

IO.puts(
  "PASS: #{length(rows)} actual native Saturation food transitions; duration/scale independence and exhaustion/timer preservation; live consumption excluded."
)
