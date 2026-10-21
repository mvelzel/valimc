# Compares ValiMC's spawn search (VMC-027d) with SpawnOracle's vanilla results.
#
#   mix run --no-start scripts/check_spawn.exs origins ORIGINS.json
#   mix run --no-start scripts/check_spawn.exs worlds WORLDS.json SCOPE
#
# `worlds` creates each world as a new world is created (`Generator.create/3`):
# SCOPE `features` decorated (VMC-025d), `terrain` terrain only.
alias Valimc.World.{Generator, Spawn}

Valimc.Protocol.Data.load!()
Valimc.World.Chunk.load!()
Valimc.World.Blocks.init!()

{mode, path, features} =
  case System.argv() do
    ["origins", path] ->
      {"origins", path, nil}

    ["worlds", path, scope] when scope in ["terrain", "features"] ->
      {"worlds", path, scope == "features"}
  end

rows = path |> File.read!() |> JSON.decode!()

created = fn seed ->
  base =
    Path.join(System.tmp_dir!(), "valimc-spawn-#{seed}-#{System.unique_integer([:positive])}")

  try do
    :ok = Generator.create(base, seed, features: features)
    %{"spawn" => [x, y, z]} = Spawn.path(base) |> File.read!() |> JSON.decode!()
    {x, y, z}
  after
    File.rm_rf!(base)
  end
end

for row <- rows do
  seed = String.to_integer(row["seed"])

  {actual, expected} =
    case mode do
      "origins" -> {Generator.spawn_origin(seed), {row["x"], row["z"]}}
      "worlds" -> {created.(seed), {row["x"], row["y"], row["z"]}}
    end

  unless actual == expected,
    do: raise("seed #{seed}: ValiMC #{inspect(actual)}, vanilla #{inspect(expected)}")
end

IO.puts(
  case mode do
    "origins" ->
      "PASS: #{length(rows)} spawn target origins equal vanilla's."

    "worlds" ->
      "PASS: #{length(rows)} new-world spawns (#{if features, do: "features", else: "terrain"}) equal vanilla's dedicated server."
  end
)
