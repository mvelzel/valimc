# Dirty scheduler capacity under live generation (VMC-077b): a fresh decorated
# world (seed 20261020, structures) finalizes N × N regions at once through its
# proto owners, as `worldgen_live.exs` does, while a probe stands in for play:
# every 10 ms an owner-like process makes one short dirty CPU call (the disk
# NBT reader on 20 filled chests, about 64 KB) and one short normal call
# (the same reader on a 100-byte root), and records how long each took. A
# probe alone, before generation starts, gives the idle cost.
#
# Reported per pass: wall time and final chunks per second; dirty CPU and
# normal scheduler utilization (`:scheduler_wall_time_all`); the probes'
# latency percentiles in microseconds.
#
#     VALIMC_PORT=0 MIX_ENV=bench mix run bench/dirty_capacity.exs OUT.json [N] [PASSES]
alias Valimc.{Native, NBT}
alias Valimc.Worldgen.Proto

[output | rest] = System.argv()
n = rest |> Enum.at(0, "3") |> String.to_integer()
passes = rest |> Enum.at(1, "2") |> String.to_integer()
seed = 20_261_020

# About 64 KB of block entities: a fraction of a millisecond of reading.
item = fn slot ->
  {:compound,
   %{
     "Slot" => {:byte, slot},
     "id" => {:string, "minecraft:diamond_sword"},
     "count" => {:int, 1},
     "components" =>
       {:compound, %{"minecraft:damage" => {:int, slot}, "minecraft:repair_cost" => {:int, 0}}}
   }}
end

chests =
  for i <- 0..19 do
    {:compound,
     %{
       "id" => {:string, "minecraft:chest"},
       "x" => {:int, i},
       "y" => {:int, 64},
       "z" => {:int, 0},
       "Items" => NBT.list(for slot <- 0..26, do: item.(slot))
     }}
  end

large = IO.iodata_to_binary(NBT.write({:compound, %{"block_entities" => NBT.list(chests)}}))
small = IO.iodata_to_binary(NBT.write({:compound, %{"DataVersion" => {:int, 4671}}}))
limits = {64 * 1024 * 1024, 2_000_000, 512}

timed = fn fun ->
  t0 = System.monotonic_time(:microsecond)
  {:ok, _} = fun.()
  System.monotonic_time(:microsecond) - t0
end

dirty_call = fn ->
  {b, nodes, d} = limits
  Native.nbt_read_dirty(large, b, nodes, d)
end

normal_call = fn ->
  {b, nodes, d} = limits
  Native.nbt_read(small, b, nodes, d)
end

probe = fn parent ->
  spawn_link(fn ->
    loop = fn loop, acc ->
      receive do
        :stop -> send(parent, {:probe, Enum.reverse(acc)})
      after
        10 -> loop.(loop, [{timed.(dirty_call), timed.(normal_call)} | acc])
      end
    end

    loop.(loop, [])
  end)
end

stop_probe = fn pid ->
  send(pid, :stop)
  receive do: ({:probe, samples} -> samples)
end

percentiles = fn list ->
  sorted = Enum.sort(list)
  at = fn q -> Enum.at(sorted, min(length(sorted) - 1, trunc(q * length(sorted)))) end

  %{
    count: length(sorted),
    p50: at.(0.5),
    p90: at.(0.9),
    p99: at.(0.99),
    max: List.last(sorted)
  }
end

summarize = fn samples ->
  %{
    dirty_us: percentiles.(Enum.map(samples, &elem(&1, 0))),
    normal_us: percentiles.(Enum.map(samples, &elem(&1, 1)))
  }
end

# Scheduler ids 1..N are the normal schedulers, then the dirty CPU ones.
:erlang.system_flag(:scheduler_wall_time, true)
sample = fn -> :erlang.statistics(:scheduler_wall_time_all) end

utilization = fn s1, s2 ->
  normal = :erlang.system_info(:schedulers)
  dirty = :erlang.system_info(:dirty_cpu_schedulers)
  before = Map.new(s1, fn {id, active, total} -> {id, {active, total}} end)

  rows =
    for {id, active, total} <- s2 do
      {a0, t0} = before[id]
      {id, (active - a0) / max(total - t0, 1)}
    end

  mean = fn range ->
    list = for {id, util} <- rows, id in range, do: util
    Float.round(Enum.sum(list) / max(length(list), 1), 3)
  end

  %{normal: mean.(1..normal), dirty_cpu: mean.((normal + 1)..(normal + dirty))}
end

if :ets.whereis(Valimc.ScopedConfig) == :undefined,
  do: :ets.new(Valimc.ScopedConfig, [:named_table, :public])

run = fn pass ->
  base = Path.join(System.tmp_dir!(), "valimc-bench-dirty-#{System.unique_integer([:positive])}")
  File.mkdir_p!(base)

  :ok =
    Valimc.World.Spec.write(base, %{
      "type" => "vanilla",
      "seed" => seed,
      "features" => true,
      "settings" => Valimc.World.GenSettings.create("minecraft:normal", nil, seed, true)
    })

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

  pid = probe.(self())
  s1 = sample.()

  {micros, results} =
    :timer.tc(fn ->
      regions
      |> Task.async_stream(&Proto.full_chunks/1,
        max_concurrency: length(regions),
        timeout: :infinity
      )
      |> Enum.map(fn {:ok, {:ok, full}} -> length(full) end)
    end)

  s2 = sample.()
  samples = stop_probe.(pid)
  File.rm_rf(base)
  final = Enum.sum(results)

  Map.merge(summarize.(samples), %{
    seconds: Float.round(micros / 1_000_000, 2),
    final: final,
    final_per_second: round(final / (micros / 1_000_000)),
    utilization: utilization.(s1, s2)
  })
end

# The probe on an idle VM.
pid = probe.(self())
Process.sleep(2_000)
idle = summarize.(stop_probe.(pid))
IO.inspect(idle, label: "idle")

# One warm-up pass compiles the worldgen states.
_ = run.(0)
measured = for pass <- 1..passes, do: run.(pass)
for m <- measured, do: IO.inspect(m, label: "#{n} × #{n} regions")

pool =
  cond do
    Code.ensure_loaded?(Valimc.Worldgen.Pool) -> apply(Valimc.Worldgen.Pool, :size, [])
    true -> "WorldgenWorkers and DecorationWorkers, each dirty CPU schedulers"
  end

{load, _} = System.cmd("uptime", [])
File.mkdir_p!(Path.dirname(output))

File.write!(
  output,
  JSON.encode!(%{
    regions: n * n,
    idle: idle,
    passes: measured,
    generation_pool: pool,
    dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
    schedulers: System.schedulers_online(),
    large_nbt_bytes: byte_size(large),
    uptime: String.trim(load),
    revision: elem(System.cmd("git", ["rev-parse", "--short", "HEAD"]), 0) |> String.trim()
  })
)
