alias Valimc.PlayerBurning
[path] = System.argv()
data = :json.decode(File.read!(path))

for row <- data["ignitions"] do
  invulnerable = Map.get(row, "invulnerable", false)

  result =
    if Map.has_key?(row, "seconds"),
      do:
        PlayerBurning.ignite_seconds(row["current"], row["seconds"], row["factor"], invulnerable),
      else: PlayerBurning.ignite_ticks(row["current"], row["ticks"], row["factor"], invulnerable)

  unless result == {:ok, %{ticks: row["next"], clear_freeze: true}} and row["frozen"] == 0,
    do: raise("Native ignition differs: #{inspect({row, result})}")
end

for row <- data["ticks"] do
  {:ok, next} = PlayerBurning.tick(row["current"], row["immune"], row["lava"])

  unless next == %{ticks: row["next"], damage: row["amount"], on_fire: row["flag"]} and
           row["calls"] == if(row["amount"] > 0, do: 1, else: 0) and
           row["source"] == if(row["amount"] > 0, do: "on_fire"),
         do: raise("Native burn tick differs: #{inspect({row, next})}")
end

for row <- data["clears"] do
  unless PlayerBurning.clear(row["current"]) == {:ok, row["next"]},
    do: raise("Native clear differs")
end

for row <- data["setters"] do
  unless PlayerBurning.assign(row["requested"], row["invulnerable"]) == {:ok, row["next"]},
    do: raise("Native mode setter differs")
end

for row <- data["lava"] do
  {:ok, next} = PlayerBurning.lava(row["current"], row["immune"], 1.0)

  unless next.ticks == row["next"] and next.damage == row["amount"] and
           row["calls"] == if(row["immune"], do: 0, else: 1) and
           row["source"] == if(row["immune"], do: nil, else: "lava"),
         do: raise("Native lava callbacks differ: #{inspect({row, next})}")
end

IO.puts(
  "PASS: #{Enum.sum_by(Map.values(data), &length/1)} native ignition/burning/clear/lava/mode cases."
)
