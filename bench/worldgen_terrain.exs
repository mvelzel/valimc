# Terrain generation throughput (VMC-024d), matched with vanilla on one thread:
# the 64 overworld chunks of one 8 × 8 area at seed 20261020. Vanilla's side
# comes from `TerrainOracle bench VANILLA.json`. The noise fill (final density
# and aquifer) is the matched comparison: `worldgen_fill_terrain` against
# vanilla's `doFill`. The whole terrain step is reported too: ValiMC's
# `worldgen_columns` (fill, material rule, carvers and the column image, with
# chunk and carver biomes shared between chunks, as vanilla shares them through
# its world region) against vanilla's fill, `buildSurface` and
# `generateCarvers` called without a world region, which looks carver biomes
# up again for every chunk.
#
#     python3 scripts/java_tool.py TerrainOracle bench bench/results/terrain-vanilla.json
#     mix run --no-start bench/worldgen_terrain.exs bench/results/terrain-vanilla.json bench/results/terrain.json
[vanilla_path, output] = System.argv()
vanilla = vanilla_path |> File.read!() |> JSON.decode!()
chunks = Enum.map(vanilla["chunks"], fn [x, z] -> {x, z} end)
seed = 20_261_020
{:ok, state} = Valimc.Worldgen.new(seed)

biomes =
  Enum.map(
    Valimc.Worldgen.biome_names(),
    &Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", &1)
  )

time = fn f ->
  {micros, {:ok, _}} = :timer.tc(f)
  micros * 1000
end

fill = fn -> Valimc.Native.worldgen_fill_terrain(state, chunks) end
# A fresh state per pass, so the biome caches start empty as for a new region.
columns = fn ->
  {:ok, fresh} = Valimc.Worldgen.new(seed)
  Valimc.Native.worldgen_columns(fresh, "minecraft:overworld", biomes, chunks)
end

for _ <- 1..3, do: {time.(fill), time.(columns)}
fill_ns = for _ <- 1..10, do: time.(fill)
columns_ns = for _ <- 1..10, do: time.(columns)
median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
per_chunk = fn ns -> Float.round(ns / length(chunks) / 1_000_000, 2) end

[vf, vt, mf, mc] =
  Enum.map(
    [vanilla["vanilla_fill_ns"], vanilla["vanilla_terrain_ns"], fill_ns, columns_ns],
    median
  )

File.write!(
  output,
  JSON.encode!(%{
    chunks: length(chunks),
    valimc_fill_ns: fill_ns,
    valimc_columns_ns: columns_ns,
    vanilla_fill_ns: vanilla["vanilla_fill_ns"],
    vanilla_terrain_ns: vanilla["vanilla_terrain_ns"],
    vanilla_runtime: vanilla["java"],
    otp: System.otp_release(),
    elixir: System.version(),
    schedulers: System.schedulers_online()
  })
)

IO.puts(
  "median ms per chunk: noise fill vanilla #{per_chunk.(vf)}, ValiMC #{per_chunk.(mf)} " <>
    "(#{Float.round(vf / mf, 2)}x); terrain vanilla #{per_chunk.(vt)} (no region), " <>
    "ValiMC #{per_chunk.(mc)} with column images"
)
