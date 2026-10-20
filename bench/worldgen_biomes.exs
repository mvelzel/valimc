# Chunk biome fill throughput (VMC-023d), matched with vanilla: the same 256
# overworld chunks at seed 20261020, one thread, climate volumes through a
# fresh cached context per chunk and 1,536 biome lookups each. Vanilla's side
# comes from `BiomeOracle bench VANILLA.json` (eight warm-up and ten timed
# passes); ValiMC runs three warm-up and ten timed passes of
# `worldgen_chunk_biomes`, which also encodes each chunk's climate targets.
#
#     python3 scripts/java_tool.py BiomeOracle bench bench/results/biomes-vanilla.json
#     mix run --no-start bench/worldgen_biomes.exs bench/results/biomes-vanilla.json bench/results/biomes.json
[vanilla_path, output] = System.argv()
vanilla = vanilla_path |> File.read!() |> JSON.decode!()
chunks = Enum.map(vanilla["chunks"], fn [x, z] -> {x, z} end)
{:ok, state} = Valimc.Worldgen.new(20_261_020)

pass = fn ->
  {micros, {:ok, _}} =
    :timer.tc(fn -> Valimc.Native.worldgen_chunk_biomes(state, "minecraft:overworld", chunks) end)

  micros * 1000
end

for _ <- 1..3, do: pass.()
valimc = for _ <- 1..10, do: pass.()
median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
per_chunk = fn ns -> ns / length(chunks) / 1000 end
{vm, vv} = {median.(valimc), median.(vanilla["vanilla_pass_ns"])}

File.write!(
  output,
  JSON.encode!(%{
    chunks: length(chunks),
    valimc_pass_ns: valimc,
    vanilla_pass_ns: vanilla["vanilla_pass_ns"],
    vanilla_runtime: vanilla["java"],
    otp: System.otp_release(),
    elixir: System.version(),
    schedulers: System.schedulers_online()
  })
)

IO.puts(
  "chunk biome fill, median per chunk: vanilla #{Float.round(per_chunk.(vv), 1)} us, " <>
    "ValiMC #{Float.round(per_chunk.(vm), 1)} us (#{Float.round(vv / vm, 2)}x)"
)
