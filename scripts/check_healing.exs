alias Valimc.PlayerHealth
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  health = %PlayerHealth{value: row["health"], maximum: row["maximum"]}
  {:ok, next} = PlayerHealth.heal(health, row["amount"])
  unless next.value == row["next"], do: raise("Native healing differs #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(rows)} native signed healing transitions; owner death/consumption excluded."
)
