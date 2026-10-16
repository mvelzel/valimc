alias Valimc.Physics.RainContact
[path] = System.argv()
rows = :json.decode(File.read!(path))
kinds = %{"none" => :none, "rain" => :rain, "snow" => :snow}

for row <- rows do
  feet = {row["feet_y"], row["feet_sky"], Map.fetch!(kinds, row["feet_precipitation"])}
  head = {row["head_y"], row["head_sky"], Map.fetch!(kinds, row["head_precipitation"])}

  unless RainContact.exposed?(row["wet"], row["surface"], feet, head) == {:ok, row["exposed"]},
    do: raise("Native rain exposure differs: #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(rows)} native Entity/Level rain exposure cases; sky/height/biome acquisition remains separate."
)
