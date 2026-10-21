alias Valimc.Protocol.Data
alias Valimc.World.Climate
# The oracle's facts describe its noise; the native temperature is checked by result.
[_facts_path, path] = System.argv()
plains = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
rows = :json.decode(File.read!(path))

for [x, y, z, temperature, precipitation] <- rows do
  <<expected::float-32>> = <<temperature::float-32>>
  actual = Climate.temperature(plains, {x, y, z}, 63)

  unless actual == expected,
    do: raise("Native temperature differs: #{inspect({x, y, z, expected, actual})}")

  unless Atom.to_string(Climate.precipitation(plains, {x, y, z}, 63)) == precipitation,
    do: raise("Native precipitation differs at #{inspect({x, y, z})}")
end

IO.puts(
  "PASS: #{length(rows)} exact native plains temperatures and precipitation kinds at sea level 63."
)
