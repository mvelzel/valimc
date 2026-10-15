alias Valimc.PlayerVoid
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  damage = PlayerVoid.damage(c["y"], c["minimum"])
  calls = if damage > 0, do: 2, else: 0
  source = if damage > 0, do: "minecraft:out_of_world", else: nil

  unless c["calls"] == calls and c["amount"] == damage and c["source"] == source,
    do: raise("Native void threshold/callback differs #{inspect({c, damage})}")
end

IO.puts(
  "PASS: #{length(cases)} native below-world threshold/callback cases; owner composition remains separate."
)
