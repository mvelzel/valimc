# Live generation throughput (VMC-025d3): a fresh decorated world at seed
# 20261020 finalizes an N × N block of regions from scratch through its proto
# owners, all regions requested at once as a server loading them would: terrain
# for the (8N + 4)² chunks around them, decoration of the (8N + 2)² chunks
# around them in finalize transactions, full chunks, and every proto log write
# (durable, as live). Reported: wall time, final chunks per second and
# generated (terrain) chunks per second, with the dirty CPU schedulers that run
# the work. Start with `elixir --erl "+SDcpu 1" -S mix run …` for one thread.
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
# proto NIFs (terrain encoded, decoration over encoded chunks, full chunks)
# against `worldgen_build_terrain` and `worldgen_decoration_time`, so the cost
# of encoding is separate from that of transactions and logs.
alias Valimc.Worldgen.Proto

[output | rest] = System.argv()
n = rest |> Enum.at(0, "4") |> String.to_integer()
passes = rest |> Enum.at(1, "3") |> String.to_integer()
structures = Enum.at(rest, 2, "structures") == "structures"
seed = 20_261_020

run = fn pass ->
  base = Path.join(System.tmp_dir!(), "valimc-bench-live-#{System.unique_integer([:positive])}")
  File.mkdir_p!(base)

  File.write!(
    Valimc.World.Spawn.path(base),
    JSON.encode!(%{
      "spawn" => [0, 100, 0],
      "generator" => %{
        "type" => "vanilla",
        "seed" => seed,
        "features" => true,
        "settings" => Valimc.World.GenSettings.create("minecraft:normal", nil, seed, structures)
      }
    })
  )

  # Each pass uses regions of its own, so no owner of an earlier pass answers.
  offset = pass * (n + 4)
  regions = for rz <- 0..(n - 1), rx <- 0..(n - 1), do: {rx + offset, rz}

  :ets.insert(
    Valimc.ScopedConfig,
    for(
      rx <- (offset - 2)..(offset + n + 1),
      rz <- -2..(n + 1),
      do: {{{rx, rz}, :world_path}, base}
    )
  )

  {micros, results} =
    :timer.tc(fn ->
      regions
      |> Task.async_stream(&Proto.full_chunks/1,
        max_concurrency: length(regions),
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, full}} -> length(full) end)
    end)

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

if :ets.whereis(Valimc.ScopedConfig) == :undefined,
  do: :ets.new(Valimc.ScopedConfig, [:named_table, :public])

# One thread: each NIF call runs on one dirty scheduler.
alias Valimc.Native
source = "minecraft:overworld"
area = for z <- -1..8, x <- -1..8, do: {x, z}
inner = for z <- 0..7, x <- 0..7, do: {x, z}

order =
  Application.app_dir(:valimc, "priv/worldgen/feature_order.json")
  |> File.read!()
  |> JSON.decode!()
  |> Map.fetch!(source)

features =
  for {step, s} <- Enum.with_index(order), i <- 0..(length(step) - 1)//1, do: {s, i}

median = fn list -> list |> Enum.sort() |> Enum.at(div(length(list), 2)) end

stage = fn f ->
  # A fresh state per pass, as a new region's generation starts.
  for pass <- 0..5 do
    {:ok, state} = Valimc.Worldgen.new(seed)
    {micros, _} = :timer.tc(fn -> f.(state) end)
    {pass, micros}
  end
  |> Enum.drop(1)
  |> Enum.map(&elem(&1, 1))
  |> median.()
end

terrain_us = stage.(fn s -> {:ok, _} = Native.worldgen_build_terrain(s, source, true, area) end)
proto_us = stage.(fn s -> {:ok, _} = Native.worldgen_proto_terrain(s, source, area) end)
{:ok, warm} = Valimc.Worldgen.new(seed)
{:ok, terrain} = Native.worldgen_proto_terrain(warm, source, area)
images = Enum.map(terrain, &elem(&1, 2))

decorate_us =
  median.(
    for _ <- 1..5 do
      {micros, {:ok, _}} =
        :timer.tc(fn -> Native.worldgen_proto_decorate(warm, images, inner) end)

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

structure_terrain_us =
  stage.(fn s -> {:ok, _} = Native.worldgen_proto_terrain(s, source, area, true) end)

{:ok, structure_terrain} = Native.worldgen_proto_terrain(warm, source, area, true)
structure_images = Enum.map(structure_terrain, &elem(&1, 2))

structure_decorate_us =
  median.(
    for _ <- 1..5 do
      {micros, {:ok, _}} =
        :timer.tc(fn ->
          Native.worldgen_proto_decorate(warm, source, structure_images, inner, true)
        end)

      micros
    end
  )

{:ok, {touched, _}} = Native.worldgen_proto_decorate(warm, images, inner)
decorated = Map.new(touched, fn {x, z, image} -> {{x, z}, image} end)
own = Enum.map(inner, &decorated[&1])

full_us =
  median.(
    for _ <- 1..5 do
      {micros, {:ok, _}} =
        :timer.tc(fn ->
          Native.worldgen_proto_full(warm, own, Valimc.World.Generator.protocol_biomes())
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

# One warm-up pass compiles the worldgen states.
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
