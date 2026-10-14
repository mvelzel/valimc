alias Valimc.World.Chunk
[file] = System.argv()
cases = file |> File.read!() |> JSON.decode!()

for [x, y, z, state] <- cases do
  if Chunk.base(y) != state or Chunk.block_at(%{{x, y, z} => 1}, {x, y, z}) != state,
    do: raise("Native outside-height state differs at #{inspect({x, y, z})}")
end

IO.puts(
  "PASS: #{length(cases)} native loaded-chunk outside-height reads, ignoring invalid edits."
)
