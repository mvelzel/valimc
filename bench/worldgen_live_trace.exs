# Where live generation's time goes (VMC-025d3): the run of
# `worldgen_live.exs` (a fresh decorated world at seed 20261020 finalizing
# N × N regions at once) with call tracing of the proto NIFs (terrain,
# decoration, full chunks), `:file.datasync/1` and the finalize transaction's
# steps per region (start, decorating, decorated, committed, busy back-offs,
# aborts),
# plus dirty CPU and normal scheduler utilization. Prints the totals, the
# number of NIFs and decorations running in each 100 ms and each region's
# timeline; writes the same as an Elixir term.
#
#     VALIMC_PORT=0 MIX_ENV=prod mix run bench/worldgen_live_trace.exs OUT.exs [N] [PASSES]
alias Valimc.Worldgen.Proto

[output | rest] = System.argv()
n = rest |> Enum.at(0, "4") |> String.to_integer()
passes = rest |> Enum.at(1, "2") |> String.to_integer()
seed = 20_261_020

if :ets.whereis(Valimc.ScopedConfig) == :undefined,
  do: :ets.new(Valimc.ScopedConfig, [:named_table, :public])

run = fn pass ->
  base = Path.join(System.tmp_dir!(), "valimc-prof-live-#{System.unique_integer([:positive])}")
  File.mkdir_p!(base)

  File.write!(
    Valimc.World.Spawn.path(base),
    JSON.encode!(%{
      "spawn" => [0, 100, 0],
      "generator" => %{"type" => "vanilla", "seed" => seed, "features" => true}
    })
  )

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

  t0 = System.monotonic_time(:microsecond)

  done =
    regions
    |> Task.async_stream(
      fn r ->
        {:ok, full} = Proto.full_chunks(r)
        {r, length(full), System.monotonic_time(:microsecond)}
      end,
      max_concurrency: length(regions),
      timeout: :infinity
    )
    |> Enum.map(fn {:ok, x} -> x end)

  t1 = System.monotonic_time(:microsecond)
  File.rm_rf(base)
  %{t0: t0, t1: t1, done: done}
end

defmodule Collector do
  def loop(acc) do
    receive do
      {:dump, from} -> send(from, {:events, Enum.reverse(acc)})
      msg -> loop([msg | acc])
    end
  end
end

_ = run.(0)

tracer = spawn(fn -> Collector.loop([]) end)
native = Valimc.Native
proto = Valimc.Worldgen.Proto

# Owners call the arities with the structures flag (VMC-025f5).
:erlang.trace_pattern(
  {native, :worldgen_proto_terrain, 4},
  [{[:_, :_, :"$1", :_], [], [{:message, {:length, :"$1"}}, {:return_trace}]}],
  [:global]
)

:erlang.trace_pattern(
  {native, :worldgen_proto_decorate, 5},
  [{[:_, :_, :_, :"$1", :_], [], [{:message, {:length, :"$1"}}, {:return_trace}]}],
  [:global]
)

:erlang.trace_pattern(
  {native, :worldgen_proto_full, 3},
  [{[:_, :_, :_], [], [{:return_trace}]}],
  [:global]
)

:erlang.trace_pattern({:file, :datasync, 1}, [{[:_], [], [{:return_trace}]}], [:global])
key = {:map_get, :key, :"$1"}
:erlang.trace_pattern({proto, :start_finalize, 1}, [{[:"$1"], [], [{:message, key}]}], [:local])
:erlang.trace_pattern({proto, :back_off, 1}, [{[:"$1"], [], [{:message, key}]}], [:local])
:erlang.trace_pattern({proto, :decorate, 1}, [{[:"$1"], [], [{:message, key}]}], [:local])
:erlang.trace_pattern({proto, :commit, 2}, [{[:"$1", :_], [], [{:message, key}]}], [:local])
:erlang.trace_pattern({proto, :deliver_all, 2}, [{[:"$1", :_], [], [{:message, key}]}], [:local])

:erlang.trace_pattern({proto, :abort, 2}, [{[:"$1", :"$2"], [], [{:message, {{key, :"$2"}}}]}], [
  :local
])

:erlang.trace(:all, true, [:call, :arity, :monotonic_timestamp, {:tracer, tracer}])

:erlang.system_flag(:scheduler_wall_time, true)

measured =
  for pass <- 1..passes do
    s1 = :erlang.statistics(:scheduler_wall_time_all)
    m = run.(pass)
    s2 = :erlang.statistics(:scheduler_wall_time_all)
    # Ids 1..N are normal schedulers, then the dirty CPU ones.
    ns = :erlang.system_info(:schedulers)
    ds = :erlang.system_info(:dirty_cpu_schedulers)
    a = Map.new(s1, fn {id, act, tot} -> {id, {act, tot}} end)

    u =
      for {id, act, tot} <- s2 do
        {a0, t0} = a[id]
        {id, (act - a0) / max(tot - t0, 1)}
      end

    util = for {id, x} <- u, id > ns and id <= ns + ds, do: x
    normal = for {id, x} <- u, id <= ns, do: x

    m
    |> Map.put(:dirty_util, Enum.sum(util) / max(length(util), 1))
    |> Map.put(:dirty_count, length(util))
    |> Map.put(:normal_util, Enum.sum(normal) / max(length(normal), 1))
    |> Map.put(:normal_count, length(normal))
  end

:erlang.trace(:all, false, [:call])
send(tracer, {:dump, self()})
events = receive do: ({:events, e} -> e)

# Trace timestamps are native monotonic time.
to_us = fn ts -> System.convert_time_unit(ts, :native, :microsecond) end

intervals =
  events
  |> Enum.reduce({%{}, []}, fn
    {:trace_ts, pid, :call, {m, f, _a}, extra, ts}, {open, acc}
    when m in [Valimc.Native, :file] ->
      {Map.put(open, {pid, f}, {to_us.(ts), extra}), acc}

    {:trace_ts, pid, :call, {m, f, _a}, ts}, {open, acc} when m in [Valimc.Native, :file] ->
      {Map.put(open, {pid, f}, {to_us.(ts), nil}), acc}

    {:trace_ts, pid, :return_from, {_m, f, _a}, _ret, ts}, {open, acc} ->
      case Map.pop(open, {pid, f}) do
        {{start, extra}, open} -> {open, [{f, start, to_us.(ts), extra} | acc]}
        {nil, open} -> {open, acc}
      end

    _, s ->
      s
  end)
  |> elem(1)

phases =
  for {:trace_ts, _pid, :call, {Valimc.Worldgen.Proto, f, _}, extra, ts} <- events,
      do: {f, extra, to_us.(ts)}

summary =
  for m <- measured do
    within = fn t -> t >= m.t0 and t <= m.t1 end
    wall = (m.t1 - m.t0) / 1000
    iv = Enum.filter(intervals, fn {_, s, _, _} -> within.(s) end)

    by = fn f ->
      list = for {^f, s, e, x} <- iv, do: {e - s, x}

      %{
        calls: length(list),
        units: list |> Enum.map(fn {_, x} -> x || 1 end) |> Enum.sum(),
        total_ms: (list |> Enum.map(&elem(&1, 0)) |> Enum.sum()) / 1000,
        max_ms: (list |> Enum.map(&elem(&1, 0)) |> Enum.max(fn -> 0 end)) / 1000
      }
    end

    # Concurrency of decorations: sample every 10 ms.
    decos = for {:worldgen_proto_decorate, s, e, _} <- iv, do: {s, e}
    nifs = for {f, s, e, _} <- iv, f != :datasync, do: {s, e}
    steps = Enum.to_list(m.t0..m.t1//10_000)

    concurrent = fn list ->
      Enum.map(steps, fn t -> Enum.count(list, fn {s, e} -> s <= t and t < e end) end)
    end

    dc = concurrent.(decos)
    nc = concurrent.(nifs)

    ph = Enum.filter(phases, fn {_, _, t} -> within.(t) end)

    txns =
      ph
      |> Enum.group_by(fn {_, x, _} ->
        if is_tuple(x) and tuple_size(x) == 2 and is_tuple(elem(x, 0)), do: elem(x, 0), else: x
      end)
      |> Enum.map(fn {k, list} -> {k, Enum.sort_by(list, &elem(&1, 2))} end)

    # Per region: first start, decorate, commit, deliver times (last successful attempt).
    per_region =
      for {k, list} <- txns do
        get = fn f -> for({^f, _, t} <- list, do: t) end
        starts = get.(:start_finalize)
        decs = get.(:decorate)
        commits = get.(:commit)
        delivers = get.(:deliver_all)
        aborts = for {:abort, {_, reason}, _} <- list, do: reason
        busy = length(get.(:back_off))

        %{
          region: inspect(k),
          starts: length(starts),
          busy: busy,
          aborts: length(aborts),
          abort_reasons: aborts |> Enum.map(&inspect/1) |> Enum.frequencies(),
          first_start_ms: if(starts != [], do: (hd(starts) - m.t0) / 1000),
          last_start_ms: if(starts != [], do: (List.last(starts) - m.t0) / 1000),
          locked_ms:
            if(decs != [] and starts != [], do: (List.last(decs) - List.last(starts)) / 1000),
          decorate_ms:
            if(commits != [] and decs != [], do: (List.last(commits) - List.last(decs)) / 1000),
          commit_ms:
            if(delivers != [] and commits != [],
              do: (List.last(delivers) - List.last(commits)) / 1000
            ),
          committed_at_ms: if(delivers != [], do: (List.last(delivers) - m.t0) / 1000)
        }
      end

    measured_regions = MapSet.new(for {r, _, _} <- m.done, do: inspect(r))

    %{
      wall_ms: wall,
      final_chunks: m.done |> Enum.map(&elem(&1, 1)) |> Enum.sum(),
      region_done_ms:
        m.done
        |> Enum.map(fn {r, _, t} -> [inspect(r), (t - m.t0) / 1000] end)
        |> Enum.sort_by(&Enum.at(&1, 1)),
      dirty_util: m.dirty_util,
      dirty_count: m.dirty_count,
      normal_util: m.normal_util,
      normal_count: m.normal_count,
      terrain: by.(:worldgen_proto_terrain),
      decorate: by.(:worldgen_proto_decorate),
      full: by.(:worldgen_proto_full),
      datasync: by.(:datasync),
      decorate_concurrency_mean: Enum.sum(dc) / max(length(dc), 1),
      decorate_concurrency_max: Enum.max(dc, fn -> 0 end),
      nif_concurrency_mean: Enum.sum(nc) / max(length(nc), 1),
      nif_timeline_100ms:
        nc |> Enum.chunk_every(10) |> Enum.map(&Float.round(Enum.sum(&1) / length(&1), 1)),
      deco_timeline_100ms:
        dc |> Enum.chunk_every(10) |> Enum.map(&Float.round(Enum.sum(&1) / length(&1), 1)),
      busy: per_region |> Enum.map(& &1.busy) |> Enum.sum(),
      aborts: per_region |> Enum.map(& &1.aborts) |> Enum.sum(),
      abort_reasons:
        per_region
        |> Enum.map(& &1.abort_reasons)
        |> Enum.reduce(%{}, &Map.merge(&1, &2, fn _, a, b -> a + b end)),
      measured_regions:
        Enum.filter(per_region, &MapSet.member?(measured_regions, &1.region))
        |> Enum.sort_by(& &1.committed_at_ms),
      border_regions:
        Enum.reject(per_region, &MapSet.member?(measured_regions, &1.region)) |> length()
    }
  end

for s <- summary do
  IO.puts(
    "wall #{round(s.wall_ms)} ms, #{s.final_chunks} final, dirty util #{Float.round(s.dirty_util * 100, 1)}% of #{s.dirty_count}, normal util #{Float.round(s.normal_util * 100, 1)}% of #{s.normal_count}"
  )

  for k <- [:terrain, :decorate, :full, :datasync], do: IO.puts("  #{k}: #{inspect(s[k])}")

  IO.puts(
    "  decorations concurrent: mean #{Float.round(s.decorate_concurrency_mean, 2)}, max #{s.decorate_concurrency_max}; NIFs concurrent mean #{Float.round(s.nif_concurrency_mean, 2)}"
  )

  IO.puts("  NIF timeline (100 ms): #{inspect(s.nif_timeline_100ms, limit: :infinity)}")
  IO.puts("  decoration timeline (100 ms): #{inspect(s.deco_timeline_100ms, limit: :infinity)}")
  IO.puts("  busy back-offs #{s.busy}, aborts #{s.aborts}: #{inspect(s.abort_reasons)}")
  for r <- s.measured_regions, do: IO.puts("  #{inspect(r)}")
end

{load, _} = System.cmd("uptime", [])
File.mkdir_p!(Path.dirname(output))

File.write!(
  output,
  inspect(%{n: n, uptime: String.trim(load), passes: summary},
    limit: :infinity,
    printable_limit: :infinity,
    pretty: true
  )
)
