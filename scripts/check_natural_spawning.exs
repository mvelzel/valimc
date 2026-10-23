# Vanilla's natural spawner (NaturalSpawnOracle) against the spawn kernel
# (VMC-042a): every scene's spawn ticks from the same level random give the
# same mobs, positions, yaws and packs and leave the random where vanilla's
# is; spawner blocks spawn as vanilla's (VMC-042b); chunk generation spawns the
# same creatures; fresh mobs despawn at
# vanilla's distances; the sky darkens as vanilla's over a day in each
# weather.
alias Valimc.Data.EntityTypes
alias Valimc.Protocol.Data

[path] = System.argv()
Valimc.World.Spawning.install!()
fixtures = :json.decode(File.read!(path))
cases = fixtures["cases"]

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

float = fn bits ->
  <<v::float-32>> = <<bits::32>>
  v
end

name = fn id -> Enum.find(EntityTypes.names(), &(EntityTypes.id(&1) == id)) end

expect = fn [type, x, y, z, yaw, school] ->
  {EntityTypes.id(type), double.(x), double.(y), double.(z), float.(yaw), school}
end

show = fn {id, x, y, z, yaw, school} -> {name.(id), x, y, z, yaw, school} end

{ticks, spawns, generated} =
  for c <- cases, c["kind"] in ["tick", "generation"], reduce: {0, 0, 0} do
    {ticks, spawns, generated} ->
      biome = Data.registry_id("minecraft:worldgen/biome", c["biome"])
      types = for [type | _] <- c["entities"], do: EntityTypes.id(type)
      {:ok, runs} = Valimc.Native.spawn_scene(c, biome, types)

      case c["kind"] do
        "generation" ->
          [{got, _}] = runs
          want = Enum.map(c["spawns"], expect)

          if got != want,
            do:
              raise(
                "#{c["name"]} chunk #{c["chunk_x"]},#{c["chunk_z"]}: #{inspect(Enum.map(got, show))}, vanilla #{inspect(Enum.map(want, show))}"
              )

          {ticks, spawns, generated + length(want)}

        "tick" ->
          Enum.zip(c["runs"], runs)
          |> Enum.with_index()
          |> Enum.reduce({ticks, spawns, generated}, fn {{[start, after_, want], {got, random}},
                                                         i},
                                                        {t, s, g} ->
            want = Enum.map(want, expect)

            if got != want or random != after_,
              do:
                raise(
                  "#{c["name"]} run #{i} (random #{start}): #{inspect(Enum.map(got, show))} ending at #{random}, vanilla #{inspect(Enum.map(want, show))} ending at #{after_}"
                )

            {t + 1, s + length(want), g}
          end)
      end
  end

# VMC-042b: the structure scenes spawn their overrides' mobs (the fixtures
# exercise them): a hut's witches, a monument's guardians, an outpost's
# pillagers, a fortress's blazes.
for {scene, type} <- [
      {"swamp_hut", "minecraft:witch"},
      {"monument", "minecraft:guardian"},
      {"pillager_outpost", "minecraft:pillager"},
      {"fortress", "minecraft:blaze"}
    ] do
  spawned =
    for %{"kind" => "tick", "name" => ^scene, "runs" => runs} <- cases,
        [_, _, list] <- runs,
        [^type | _] <- list,
        do: 1

  if spawned == [], do: raise("the #{scene} scene spawned no #{type}")
end

# VMC-042b: spawner blocks tick as vanilla's: the same spawns, the same
# delay after every tick, the random left where vanilla's is.
{spawner_ticks, spawner_spawns} =
  for %{"kind" => "spawner"} = c <- cases, reduce: {0, 0} do
    {ticks, spawns} ->
      biome = Data.registry_id("minecraft:worldgen/biome", c["biome"])
      {:ok, runs} = Valimc.Native.spawn_spawner_scene(c, biome, EntityTypes.id(c["type"]))

      Enum.zip(c["runs"], runs)
      |> Enum.with_index()
      |> Enum.reduce({ticks, spawns}, fn {{[start, after_, want], {got, random}}, i}, {t, s} ->
        want = for [delay, list] <- want, do: {delay, Enum.map(list, &expect.(Enum.take(&1, 6)))}

        case Enum.find_index(Enum.zip(got, want), fn {a, b} -> a != b end) do
          nil when random == after_ ->
            :ok

          tick ->
            {ours, theirs} = if tick, do: Enum.at(Enum.zip(got, want), tick), else: {nil, nil}

            raise(
              "#{c["name"]} run #{i} (random #{start}) tick #{inspect(tick)}: #{inspect(ours)}, " <>
                "vanilla #{inspect(theirs)}; random #{random}, vanilla #{after_}"
            )
        end

        {t + length(want), s + Enum.sum(for {_, list} <- want, do: length(list))}
      end)
  end

unless spawner_ticks >= 20_000 and spawner_spawns >= 300,
  do: raise("Incomplete spawner fixtures: #{spawner_ticks} ticks, #{spawner_spawns} spawns")

unless ticks >= 20_000 and spawns >= 10_000 and generated >= 100,
  do:
    raise(
      "Incomplete natural spawning fixtures: #{ticks} ticks, #{spawns} spawns, #{generated} generated"
    )

[%{"cases" => despawns}] = for %{"kind" => "despawn"} = c <- cases, do: c

for [type, difficulty, distance, persistent, removed, idle] = row <- despawns do
  {:ok, got} =
    Valimc.Native.spawn_despawn(EntityTypes.id(type), difficulty, distance * 1.0, persistent)

  if got != {removed, idle}, do: raise("despawn #{inspect(row)}: #{inspect(got)}")
end

[%{"rows" => rows}] = for %{"kind" => "sky"} = c <- cases, do: c

for %{"rain" => rain, "thunder" => thunder, "darken" => darken} <- rows do
  want = for <<digit::binary-1 <- darken>>, do: String.to_integer(digit, 16)

  got =
    for t <- 0..23_999,
        do:
          Valimc.World.Spawning.darken(
            "minecraft:overworld",
            t + 72_000,
            rain * 1.0,
            thunder * 1.0
          )

  case Enum.find(Enum.zip([0..23_999, got, want]), fn {_, a, b} -> a != b end) do
    nil ->
      :ok

    {t, a, b} ->
      raise("sky darken at #{t} (rain #{rain}, thunder #{thunder}): #{a}, vanilla #{b}")
  end
end

IO.puts(
  "PASS: #{ticks} spawn ticks (#{spawns} mobs), #{spawner_ticks} spawner ticks " <>
    "(#{spawner_spawns} mobs) and #{generated} generated creatures equal vanilla's; " <>
    "#{length(despawns)} despawn checks and #{length(rows) * 24_000} sky darkenings match."
)
