# Decoration throughput (VMC-025), matched with vanilla on one thread: seed
# 20261020, the 8 × 8 chunks from (0, 0) decorated (Z outer, X inner) in a
# 10 × 10 terrain area from (-1, -1), with the placed features ValiMC
# implements (the oracle's list); terrain excluded from the timing. Vanilla's
# side runs vanilla's own features through the decoration oracle's
# `WorldGenLevel` over proto chunks.
#
#     python3 scripts/java_tool.py DecorationOracle bench/results/decoration-vanilla.json TYPES bench
#     mix run --no-start bench/worldgen_decoration.exs bench/results/decoration-vanilla.json \
#       bench/results/decoration.json
[vanilla_path, output] = System.argv()
vanilla = vanilla_path |> File.read!() |> JSON.decode!()

features =
  for {step, index} <- Enum.with_index(vanilla["features"]),
      [global, _id] <- step,
      do: {index, global}

order = for z <- 0..7, x <- 0..7, do: {x, z}

time = fn ->
  {:ok, state} = Valimc.Worldgen.new(20_261_020)

  {:ok, ns} =
    Valimc.Native.worldgen_decoration_time(
      state,
      "minecraft:overworld",
      {-1, -1},
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
    placed_features: length(features),
    valimc_decoration_ns: ours,
    vanilla_decoration_ns: vanilla["vanilla_decoration_ns"],
    vanilla_runtime: vanilla["java"],
    otp: System.otp_release(),
    elixir: System.version()
  })
)

IO.puts(
  "median ms per chunk, #{length(features)} placed features: ValiMC #{ms.(ours)}, " <>
    "vanilla #{ms.(vanilla["vanilla_decoration_ns"])}"
)
