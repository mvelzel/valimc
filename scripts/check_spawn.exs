# Compares ValiMC's spawn search (VMC-027d) with SpawnOracle's vanilla results.
#
#   mix run --no-start scripts/check_spawn.exs origins ORIGINS.json
#   mix run --no-start scripts/check_spawn.exs worlds WORLDS.json
alias Valimc.World.{Generator, SpawnSearch}

Valimc.Protocol.Data.load!()
Valimc.World.Chunk.load!()
Valimc.World.Blocks.init!()

[mode, path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  seed = String.to_integer(row["seed"])

  {actual, expected} =
    case mode do
      "origins" -> {Generator.spawn_origin(seed), {row["x"], row["z"]}}
      "worlds" -> {SpawnSearch.world_spawn({:vanilla, seed}), {row["x"], row["y"], row["z"]}}
    end

  unless actual == expected,
    do: raise("seed #{seed}: ValiMC #{inspect(actual)}, vanilla #{inspect(expected)}")
end

IO.puts(
  case mode do
    "origins" -> "PASS: #{length(rows)} spawn target origins equal vanilla's."
    "worlds" -> "PASS: #{length(rows)} new-world spawns equal vanilla's dedicated server."
  end
)
