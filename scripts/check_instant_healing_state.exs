alias Valimc.Living.{Effects, Health}
alias Valimc.Player.Consumption
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  {:ok, {:heal, amount}} = Effects.instant(5, row["amplifier"])
  {:ok, health} = Health.heal(%Health{value: row["before"]}, amount)

  admitted =
    Consumption.admitted_effects?([{5, [{1, row["amplifier"], false, true, true}]}])

  unless health.value == row["after"] and row["dead_or_dying"] == health.value <= 0 and
           row["dead_flag"] == false and row["die_calls"] == 0 and row["death_ticks"] == 0 and
           admitted == amount >= 0,
         do: raise("Native instant-healing callback differs #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(rows)} native instant-healing callbacks/health/dead predicates, without die calls or immediate death ticks; later lifecycle excluded."
)
