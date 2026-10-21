# Structure start throughput (VMC-025e), matched with vanilla on one thread:
# seed 20261020, the overworld's 40 × 40 chunks from (-20, -20), each through
# `createStructures` as a fresh chunk. Two warm-up and five timed passes; the
# structure state (stronghold rings included) is built during the warm-up on
# both sides. Vanilla's side runs vanilla's own generator through the oracle.
# Thread CPU time is the comparison on a shared host; wall time is kept too.
#
#     python3 scripts/java_tool.py StructureOracle bench bench/results/structures-vanilla.json
#     mix run --no-start bench/worldgen_structures.exs bench/results/structures-vanilla.json \
#       bench/results/structures.json
[vanilla_path, output] = System.argv()
vanilla = vanilla_path |> File.read!() |> JSON.decode!()
{:ok, state} = Valimc.Worldgen.new(20_261_020)

time = fn ->
  {:ok, result} =
    Valimc.Native.worldgen_structure_time(state, "minecraft:overworld", {-20, -20}, 40)

  result
end

for _ <- 1..2, do: time.()
runs = for _ <- 1..5, do: time.()
ours = Enum.map(runs, &elem(&1, 0))
ours_cpu = Enum.map(runs, &elem(&1, 1))
{_, _, starts} = hd(runs)
median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end
us = fn ns -> Float.round(median.(ns) / 1600 / 1000, 2) end

File.write!(
  output,
  JSON.encode!(%{
    chunks: 1600,
    starts: starts,
    vanilla_starts: vanilla["starts"],
    valimc_structure_start_ns: ours,
    valimc_structure_start_cpu_ns: ours_cpu,
    vanilla_structure_start_ns: vanilla["vanilla_structure_start_ns"],
    vanilla_structure_start_cpu_ns: vanilla["vanilla_structure_start_cpu_ns"],
    vanilla_runtime: vanilla["java"],
    otp: System.otp_release(),
    elixir: System.version()
  })
)

IO.puts(
  "median µs per chunk over 1600 chunks (#{starts} starts, vanilla #{vanilla["starts"]}), " <>
    "thread CPU: ValiMC #{us.(ours_cpu)}, vanilla #{us.(vanilla["vanilla_structure_start_cpu_ns"])}; " <>
    "wall: ValiMC #{us.(ours)}, vanilla #{us.(vanilla["vanilla_structure_start_ns"])}"
)
