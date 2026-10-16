alias Valimc.World.FlatClimate
[facts_path, path] = System.argv()

unless :json.decode(File.read!(facts_path)) ==
         :json.decode(File.read!("priv/physics/flat_climate.json")),
       do: raise("Native flat-climate facts differ")

rows = :json.decode(File.read!(path))

for [x, y, z, temperature, precipitation] <- rows do
  <<expected::float-32>> = <<temperature::float-32>>

  unless FlatClimate.temperature({x, y, z}) == {:ok, expected},
    do:
      raise(
        "Native temperature differs: #{inspect({x, y, z, expected, FlatClimate.temperature({x, y, z})})}"
      )

  {:ok, result} = FlatClimate.precipitation({x, y, z})

  unless Atom.to_string(result) == precipitation,
    do: raise("Native precipitation differs at #{inspect({x, y, z})}")
end

IO.puts(
  "PASS: #{length(rows)} exact native flat-plains temperatures and precipitation kinds; no biome generation."
)
