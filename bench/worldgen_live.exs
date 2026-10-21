# Live generation throughput (VMC-025d3): a fresh decorated world at seed
# 20261020 finalizes an N × N block of regions from scratch through its proto
# owners, all regions requested at once as a server loading them would: terrain
# for the (8N + 4)² chunks around them, decoration of the (8N + 2)² chunks
# around them in finalize transactions, full chunks, and every proto log write
# (durable, as live). Reported: wall time, final chunks per second and
# generated (terrain) chunks per second, with the dirty CPU schedulers that run
# the work. Start with `elixir --erl "+SDcpu 1" -S mix run …` for one thread.
#
#     VALIMC_PORT=0 mix run bench/worldgen_live.exs bench/results/live.json [N] [PASSES]
alias Valimc.Worldgen.Proto

[output | rest] = System.argv()
n = rest |> Enum.at(0, "4") |> String.to_integer()
passes = rest |> Enum.at(1, "3") |> String.to_integer()
seed = 20_261_020

run = fn pass ->
  base = Path.join(System.tmp_dir!(), "valimc-bench-live-#{System.unique_integer([:positive])}")
  File.mkdir_p!(base)

  File.write!(
    Valimc.World.Spawn.path(base),
    JSON.encode!(%{
      "spawn" => [0, 100, 0],
      "generator" => %{"type" => "vanilla", "seed" => seed, "features" => true}
    })
  )

  # Each pass uses regions of its own, so no owner of an earlier pass answers.
  offset = pass * (n + 4)
  regions = for rz <- 0..(n - 1), rx <- 0..(n - 1), do: {rx + offset, rz}
  :ets.insert(Valimc.ScopedConfig, for(rx <- (offset - 2)..(offset + n + 1), rz <- -2..(n + 1), do: {{{rx, rz}, :world_path}, base}))

  {micros, results} =
    :timer.tc(fn ->
      regions
      |> Task.async_stream(&Proto.full_chunks/1, max_concurrency: length(regions), timeout: :infinity)
      |> Enum.map(fn {:ok, {:ok, full}} -> length(full) end)
    end)

  File.rm_rf(base)
  final = Enum.sum(results)
  side = 8 * n
  %{micros: micros, final: final, terrain: (side + 4) * (side + 4), decorated: (side + 2) * (side + 2)}
end

if :ets.whereis(Valimc.ScopedConfig) == :undefined,
  do: :ets.new(Valimc.ScopedConfig, [:named_table, :public])

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
    passes: Enum.map(measured, &Map.new(&1)),
    dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
    schedulers: System.schedulers_online(),
    uptime: String.trim(load),
    revision: elem(System.cmd("git", ["rev-parse", "--short", "HEAD"]), 0) |> String.trim()
  })
)
