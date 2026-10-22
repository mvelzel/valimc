# Live generation throughput (VMC-025d3, VMC-077n): a fresh decorated world at
# seed 20261020 makes an N × N block of regions full from scratch through its
# generation scheduler, all regions requested at once as a server loading them
# would: terrain for the (8N + 4)² chunks around them, decoration of the
# (8N + 2)² chunks around them, then full chunks (lit, as regions store them;
# regions persisting them is not part of it, and the scheduler writes nothing).
# Reported: wall time, final chunks per second and generated (terrain) chunks
# per second, with the dirty CPU schedulers that run the work. Start with
# `elixir --erl "+SDcpu 1" -S mix run …` for one thread.
#
#     VALIMC_PORT=0 mix run bench/worldgen_live.exs bench/results/live.json [N] [PASSES] [structures|nostructures]
#
# VMC-025f5: the world generates structures unless `nostructures`, and the
# one-thread stages also time terrain with beards and decoration with
# structures.
#
# It first times the stages on one thread over the 64 chunks of the bench area
# of `worldgen_terrain.exs` and `worldgen_decoration.exs` (seed 20261020, the
# 8 × 8 from (0, 0) decorated Z outer, X inner in a 10 × 10 terrain area): the
# scheduler's job NIFs (terrain cells, a decoration per chunk over its 3 × 3,
# full chunks) against `worldgen_build_terrain` and
# `worldgen_decoration_time`.
alias Valimc.Native
alias Valimc.World.RegionGeneration
alias Valimc.Worldgen.Scheduler

[output | rest] = System.argv()
n = rest |> Enum.at(0, "4") |> String.to_integer()
passes = rest |> Enum.at(1, "3") |> String.to_integer()
structures = Enum.at(rest, 2, "structures") == "structures"
seed = 20_261_020

run = fn pass ->
  base = Path.join(System.tmp_dir!(), "valimc-bench-live-#{System.unique_integer([:positive])}")
  File.mkdir_p!(base)

  :ok =
    Valimc.World.Spec.write(base, %{
      "type" => "vanilla",
      "seed" => seed,
      "features" => true,
      "settings" => Valimc.Worldgen.GenSettings.create("minecraft:normal", nil, seed, structures)
    })

  # Each pass generates regions of its own, so the seed's shared caches do
  # not carry an earlier pass's chunks.
  offset = pass * (n + 4)
  regions = for rz <- 0..(n - 1), rx <- 0..(n - 1), do: {rx + offset, rz}
  {:ok, _} = Scheduler.whereis(base, :overworld)

  {micros, results} =
    :timer.tc(fn ->
      regions
      |> Task.async_stream(
        &Scheduler.full_chunks(base, :overworld, RegionGeneration.chunks_of(&1)),
        max_concurrency: length(regions),
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, full}} -> length(full) end)
    end)

  for {pid, _} <- Registry.lookup(Valimc.Worldgen.Schedulers, {base, :overworld}),
      do: Process.exit(pid, :kill)

  File.rm_rf(base)
  final = Enum.sum(results)
  side = 8 * n

  %{
    micros: micros,
    final: final,
    terrain: (side + 4) * (side + 4),
    decorated: (side + 2) * (side + 2)
  }
end

# One thread: each NIF call runs on one dirty scheduler.
source = "minecraft:overworld"
area = for z <- -1..8, x <- -1..8, do: {x, z}
inner = for z <- 0..7, x <- 0..7, do: {x, z}
around = fn {x, z} -> for dz <- -1..1, dx <- -1..1, do: {x + dx, z + dz} end

order =
  Application.app_dir(:valimc, "priv/worldgen/feature_order.json")
  |> File.read!()
  |> JSON.decode!()
  |> Map.fetch!(source)

features =
  for {step, s} <- Enum.with_index(order), i <- 0..(length(step) - 1)//1, do: {s, i}

median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end

stage = fn f ->
  # A fresh context per pass, as a new world's generation starts.
  for pass <- 0..5 do
    {:ok, state} = Valimc.Worldgen.new(seed)
    {micros, _} = :timer.tc(fn -> f.(state) end)
    {pass, micros}
  end
  |> Enum.drop(1)
  |> Enum.map(&elem(&1, 1))
  |> median.()
end

# Terrain cells of `area`, with `starts` (a start table) for beards.
cells = fn state, starts ->
  Map.new(area, fn {x, z} = chunk ->
    {:ok, cell} = Native.gen_terrain(state, source, starts, x, z)
    {chunk, cell}
  end)
end

# Decorate `inner` in order, each chunk over its 3 × 3.
decorate = fn state, starts, cells ->
  for chunk <- inner do
    {:ok, _} =
      Native.gen_decorate(state, source, starts, chunk, Enum.map(around.(chunk), &cells[&1]))
  end
end

terrain_us = stage.(fn s -> {:ok, _} = Native.worldgen_build_terrain(s, source, true, area) end)
proto_us = stage.(fn s -> cells.(s, nil) end)
{:ok, warm} = Valimc.Worldgen.new(seed)

decorate_us =
  median.(
    for _ <- 1..5 do
      fresh = cells.(warm, nil)
      {micros, _} = :timer.tc(fn -> decorate.(warm, nil, fresh) end)
      micros
    end
  )

parity_ns =
  median.(
    for _ <- 1..5 do
      {:ok, ns} = Native.worldgen_decoration_time(warm, source, {-1, -1}, 10, inner, features)
      ns
    end
  )

structure_terrain_us = stage.(fn s -> cells.(s, Native.gen_starts_new()) end)

structure_decorate_us =
  median.(
    for _ <- 1..5 do
      starts = Native.gen_starts_new()
      fresh = cells.(warm, starts)
      {micros, _} = :timer.tc(fn -> decorate.(warm, starts, fresh) end)
      micros
    end
  )

decorated = cells.(warm, nil)
decorate.(warm, nil, decorated)

full_us =
  median.(
    for _ <- 1..5 do
      {micros, _} =
        :timer.tc(fn ->
          for chunk <- inner do
            {:ok, _} =
              Native.gen_full(warm, decorated[chunk], Valimc.Worldgen.Generator.protocol_biomes())
          end
        end)

      micros
    end
  )

stages = %{
  build_terrain_ms_per_chunk: terrain_us / 100 / 1000,
  proto_terrain_ms_per_chunk: proto_us / 100 / 1000,
  proto_decorate_ms_per_chunk: decorate_us / 64 / 1000,
  decoration_ms_per_chunk: parity_ns / 64 / 1_000_000,
  proto_full_ms_per_chunk: full_us / 64 / 1000,
  proto_terrain_structures_ms_per_chunk: structure_terrain_us / 100 / 1000,
  proto_decorate_structures_ms_per_chunk: structure_decorate_us / 64 / 1000
}

IO.inspect(stages, label: "one thread")

# One warm-up pass compiles the seed's context.
_ = run.(0)
measured = for pass <- 1..passes, do: run.(pass)

for m <- measured do
  seconds = m.micros / 1_000_000

  IO.puts(
    "#{n} × #{n} regions: #{Float.round(seconds, 2)} s, " <>
      "#{round(m.final / seconds)} final chunks/s, #{round(m.terrain / seconds)} terrain chunks/s"
  )
end

{load, _} = System.cmd("uptime", [])

File.mkdir_p!(Path.dirname(output))

File.write!(
  output,
  JSON.encode!(%{
    regions: n * n,
    structures: structures,
    stages: stages,
    passes: Enum.map(measured, &Map.new(&1)),
    dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
    schedulers: System.schedulers_online(),
    uptime: String.trim(load),
    revision: elem(System.cmd("git", ["rev-parse", "--short", "HEAD"]), 0) |> String.trim()
  })
)
