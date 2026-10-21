# Terrain generation throughput (VMC-024, VMC-026), matched with vanilla and
# Pumpkin on one thread: the 64 chunks of one 8 × 8 area at seed 20261020, of
# the overworld or of the dimension the vanilla timings name (`TerrainOracle
# bench OUT nether|end X0 Z0`; Pumpkin's `valimc_dimension_terrain`).
#
# - Noise fill (final density and aquifer): `worldgen_fill_terrain` against
#   vanilla's `doFill` (`TerrainOracle bench VANILLA.json`) and Pumpkin's noise
#   stage.
# - Terrain through carvers (chunk biomes, noise, material rule, carvers):
#   `worldgen_build_terrain` from a fresh state per pass, so biome caches start
#   empty as for a new region, against Pumpkin's biome, noise, surface and
#   carver stages. Vanilla's fill, `buildSurface` and `generateCarvers` are
#   reported too, but without a world region they look carver biomes up again
#   for every chunk, so that number is not matched.
# - `worldgen_columns` adds the column image ValiMC stores.
#
# Pumpkin's side comes from a local harness over Pumpkin's public chunk-stage
# API (see the VMC-024 ticket); it also writes Pumpkin's carved blocks, which
# this script compares with ValiMC's (equal to vanilla's by the
# `worldgen_carvers` stage).
#
#     python3 scripts/java_tool.py TerrainOracle bench bench/results/terrain-vanilla.json
#     mix run --no-start bench/worldgen_terrain.exs bench/results/terrain-vanilla.json \
#       bench/results/terrain.json [PUMPKIN.json PUMPKIN-BLOCKS.bin]
defmodule BlockDiff do
  def count(<<a::16, ra::binary>>, <<b::16, rb::binary>>, n),
    do: count(ra, rb, if(a == b, do: n, else: n + 1))

  def count(<<>>, <<>>, n), do: n
end

[vanilla_path, output | pumpkin_paths] = System.argv()
vanilla = vanilla_path |> File.read!() |> JSON.decode!()
chunks = Enum.map(vanilla["chunks"], fn [x, z] -> {x, z} end)
seed = 20_261_020
settings = Map.get(vanilla, "noise_settings", "minecraft:overworld")
biome_source = Map.get(vanilla, "biome_source", "minecraft:overworld")
height = Map.get(vanilla, "height", 384)
{:ok, state} = Valimc.Worldgen.new(seed, settings)

biomes =
  Enum.map(
    Valimc.Worldgen.biome_names(),
    &Valimc.Protocol.Data.registry_id("minecraft:worldgen/biome", &1)
  )

time = fn f ->
  {micros, {:ok, _}} = :timer.tc(f)
  micros * 1000
end

fresh = fn ->
  {:ok, fresh} = Valimc.Worldgen.new(seed, settings)
  fresh
end

fill = fn -> Valimc.Native.worldgen_fill_terrain(state, chunks) end

terrain = fn ->
  Valimc.Native.worldgen_build_terrain(fresh.(), biome_source, true, chunks)
end

columns = fn ->
  Valimc.Native.worldgen_columns(fresh.(), biome_source, biomes, chunks)
end

for _ <- 1..3, do: {time.(fill), time.(terrain), time.(columns)}
fill_ns = for _ <- 1..10, do: time.(fill)
terrain_ns = for _ <- 1..10, do: time.(terrain)
columns_ns = for _ <- 1..10, do: time.(columns)
median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
ms = fn ns -> Float.round(median.(ns) / length(chunks) / 1_000_000, 2) end

pumpkin =
  case pumpkin_paths do
    [json, blocks] ->
      timings = json |> File.read!() |> JSON.decode!()
      true = timings["chunks"] == vanilla["chunks"]

      total =
        Enum.zip_with(
          ~w(pumpkin_biomes_ns pumpkin_noise_ns pumpkin_surface_ns pumpkin_carvers_ns)
          |> Enum.map(&timings[&1]),
          &Enum.sum/1
        )

      {:ok, ours} =
        Valimc.Native.worldgen_build_terrain(fresh.(), biome_source, true, chunks)

      ours = Enum.map_join(ours, fn {blocks, _} -> blocks end)

      theirs =
        for <<id::little-16 <- File.read!(blocks)>>, into: <<>>, do: <<id::16>>

      differing = BlockDiff.count(ours, theirs, 0)

      Map.merge(timings, %{"pumpkin_terrain_ns" => total, "pumpkin_blocks_differing" => differing})

    [] ->
      %{}
  end

File.write!(
  output,
  JSON.encode!(
    Map.merge(pumpkin, %{
      chunks: length(chunks),
      noise_settings: settings,
      valimc_fill_ns: fill_ns,
      valimc_terrain_ns: terrain_ns,
      valimc_columns_ns: columns_ns,
      vanilla_fill_ns: vanilla["vanilla_fill_ns"],
      vanilla_terrain_ns: vanilla["vanilla_terrain_ns"],
      vanilla_runtime: vanilla["java"],
      otp: System.otp_release(),
      elixir: System.version(),
      schedulers: System.schedulers_online()
    })
  )
)

IO.puts("median ms per chunk:")

IO.puts(
  "  noise fill: ValiMC #{ms.(fill_ns)}, vanilla #{ms.(vanilla["vanilla_fill_ns"])}" <>
    if(pumpkin == %{}, do: "", else: ", Pumpkin #{ms.(pumpkin["pumpkin_noise_ns"])}")
)

IO.puts(
  "  through carvers: ValiMC #{ms.(terrain_ns)}" <>
    if(pumpkin == %{}, do: "", else: ", Pumpkin #{ms.(pumpkin["pumpkin_terrain_ns"])}") <>
    " (vanilla without a region: #{ms.(vanilla["vanilla_terrain_ns"])})"
)

IO.puts("  with column images: ValiMC #{ms.(columns_ns)}")

if pumpkin != %{} do
  IO.puts(
    "  Pumpkin stages: biomes #{ms.(pumpkin["pumpkin_biomes_ns"])}, " <>
      "surface #{ms.(pumpkin["pumpkin_surface_ns"])}, carvers #{ms.(pumpkin["pumpkin_carvers_ns"])}; " <>
      "#{pumpkin["pumpkin_blocks_differing"]} of #{length(chunks) * 256 * height} blocks differ from ValiMC's"
  )
end
