# Decoration throughput (VMC-025, VMC-026a), matched with vanilla on one
# thread: seed 20261020, the 8 × 8 chunks of the oracle's area (the
# overworld's and the Nether's from (0, 0), the End's outer islands from
# (100, 0)) decorated (Z outer, X inner) in a 10 × 10 terrain area around
# them, with the placed features the oracle included; terrain excluded from
# the timing. Vanilla's side runs vanilla's own features through the
# decoration oracle's `WorldGenLevel` over proto chunks.
#
#     python3 scripts/java_tool.py DecorationOracle bench/results/decoration-vanilla.json TYPES [nether|end] bench
#     mix run --no-start bench/worldgen_decoration.exs bench/results/decoration-vanilla.json \
#       bench/results/decoration.json
[vanilla_path, output] = System.argv()
vanilla = vanilla_path |> File.read!() |> JSON.decode!()
settings = Map.get(vanilla, "noise_settings", "minecraft:overworld")
biome_source = Map.get(vanilla, "biome_source", "minecraft:overworld")
{x0, z0} = {Map.get(vanilla, "x", 0), Map.get(vanilla, "z", 0)}

features =
  for {step, index} <- Enum.with_index(vanilla["features"]),
      [global, _id] <- step,
      do: {index, global}

order = for z <- z0..(z0 + 7), x <- x0..(x0 + 7), do: {x, z}

time = fn ->
  {:ok, state} = Valimc.Worldgen.new(20_261_020, settings)

  {:ok, ns} =
    Valimc.Native.worldgen_decoration_time(
      state,
      biome_source,
      {x0 - 1, z0 - 1},
      10,
      order,
      features
    )

  ns
end

for _ <- 1..2, do: time.()
ours = for _ <- 1..5, do: time.()
median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
ms = fn ns -> Float.round(median.(ns) / 64 / 1_000_000, 3) end

File.write!(
  output,
  JSON.encode!(%{
    biome_source: biome_source,
    origin: [x0, z0],
    placed_features: length(features),
    valimc_decoration_ns: ours,
    vanilla_decoration_ns: vanilla["vanilla_decoration_ns"],
    vanilla_runtime: vanilla["java"],
    otp: System.otp_release(),
    elixir: System.version()
  })
)

IO.puts(
  "median ms per chunk, #{biome_source}, #{length(features)} placed features: ValiMC #{ms.(ours)}, " <>
    "vanilla #{ms.(vanilla["vanilla_decoration_ns"])}"
)
