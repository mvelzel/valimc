# VMC-081a: the fixed-workload tick budget harness. One real loopback client
# plays a vanilla world (seed 20261020) at the hosted settings, view 32 and
# simulation 10, on the schedulers the VM was started with (the host has two:
# start with `--erl "+S 2:2 +SDcpu 2:2"`). It reports the owner hosting the
# player: completed ticks per second, tick and other callback percentiles,
# sampled phase means, heap, collections and scheduler use.
#
# `prepare` generates the template world once: the player's whole view around
# the spawn, with the animals generation places. Each run copies it, so every
# run starts from the same terrain and population.
#
#   MIX_ENV=bench mix run --no-start bench/tick_budget.exs prepare TEMPLATE
#   MIX_ENV=bench elixir --erl "+S 2:2 +SDcpu 2:2" -S mix run --no-start \
#     bench/tick_budget.exs run TEMPLATE OUTPUT combat|explore [SECONDS]
#
# `combat` (capture 8): survival at midnight with the daylight cycle paused, so
# hostiles spawn to the cap and attack; the player respawns where it died.
# A minute of warm-up fills the caps before measuring. `explore` (capture 9): a
# spectator flies at 20 blocks/s along +X into terrain nothing generated,
# moving only while its chunk is there, as the vanilla client does.
alias Valimc.Data.ProfileWork
alias Valimc.Protocol.{Data, Wire}

defmodule Bench.TickBudget do
  @seed 20_261_020
  @distance 32
  @name "TickBudget"

  def configure(world) do
    for {key, value} <- [
          world_path: world,
          port: 0,
          generator: :vanilla,
          seed: @seed,
          default_game_mode: :survival,
          view_distance: @distance,
          simulation_distance: 10,
          worldgen_proto_cells: 128,
          console: false,
          encrypt_login: false,
          online_mode: false,
          operators: :all
        ],
        do: Application.put_env(:valimc, key, value)

    # `PROFILE_EVERY=1` partitions every tick into phases (the last hundred
    # are reported) instead of every twentieth.
    if words = System.get_env("MIN_HEAP"),
      do: Application.put_env(:valimc, :region_min_heap_words, String.to_integer(words))

    if every = System.get_env("PROFILE_EVERY"),
      do: Application.put_env(:valimc, :profile_sample_every, String.to_integer(every))

    # As a release does: checkpoints decode with `:safe`, which refuses atoms
    # of modules `mix run` has not loaded yet.
    _ = Application.load(:valimc)
    for module <- Application.spec(:valimc, :modules), do: Code.ensure_loaded!(module)
    {:ok, _} = Application.ensure_all_started(:valimc)
  end

  ## The client: one process owns the socket, answers what the vanilla client
  ## must, and moves once per 50 ms when told to fly.

  def join(parent) do
    {:ok, socket} =
      :gen_tcp.connect(
        {127, 0, 0, 1},
        Valimc.Net.Listener.port(),
        [:binary, active: false],
        5000
      )

    client =
      %{socket: socket, buffer: <<>>, threshold: nil}
      |> send_packet(:handshake, "intention", [
        Wire.varint(777),
        Wire.string("localhost"),
        <<25565::16, 2>>
      ])
      |> send_packet(:login, "hello", [Wire.string(@name), <<0::128>>])

    {body, client} = await(client, :login, "login_compression")
    {threshold, <<>>} = Wire.take_varint(body)
    client = %{client | threshold: threshold}
    {_, client} = await(client, :login, "login_finished")
    client = send_packet(client, :login, "login_acknowledged", <<>>)
    {packs, client} = await(client, :configuration, "select_known_packs")

    client =
      client
      |> send_packet(:configuration, "client_information", [
        Wire.string("en_us"),
        <<@distance::signed-8, 0, 1, 0x7F, 1, 0, 1, 0>>
      ])
      |> send_packet(:configuration, "select_known_packs", packs)

    {_, client} = await(client, :configuration, "finish_configuration")
    client = send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = await(client, :play, "login")
    client = send_packet(client, :play, "player_loaded", <<>>)

    state = %{
      client: client,
      parent: parent,
      have: MapSet.new(),
      chunks: 0,
      deaths: 0,
      position: nil,
      fly: nil,
      due: now_ms(),
      missing_ms: 0
    }

    loop(state)
  end

  defp loop(state) do
    receive do
      {:fly, speed} ->
        loop(%{state | fly: speed / 20, due: now_ms()})

      {:report, from} ->
        report = Map.drop(state, [:client, :have, :parent])
        send(from, {:client, Map.put(report, :loaded, MapSet.size(state.have))})
        loop(state)
    after
      0 ->
        wait = max(0, state.due - now_ms())

        state =
          case read(state.client, wait) do
            {:timeout, client} ->
              tick(%{state | client: client})

            {id, body, client} ->
              handle(Data.name(:play, :clientbound, id), body, %{state | client: client})
          end

        loop(state)
    end
  end

  # One client tick: a flying player moves along +X while its chunk is there.
  defp tick(%{fly: nil} = state), do: %{state | due: state.due + 50}

  defp tick(%{position: {x, y, z}} = state) do
    {x, missing} =
      if MapSet.member?(state.have, {floor(x / 16), floor(z / 16)}),
        do: {x + state.fly, 0},
        else: {x, 50}

    client =
      state.client
      |> send_packet(:play, "move_player_pos", <<x::float-64, y::float-64, z::float-64, 0>>)
      |> send_packet(:play, "client_tick_end", <<>>)

    %{
      state
      | client: client,
        position: {x, y, z},
        due: state.due + 50,
        missing_ms: state.missing_ms + missing
    }
  end

  defp tick(state), do: %{state | due: state.due + 50}

  defp handle("level_chunk_with_light", <<x::signed-32, z::signed-32, _::binary>>, state),
    do: %{state | have: MapSet.put(state.have, {x, z}), chunks: state.chunks + 1}

  defp handle("forget_level_chunk", <<z::signed-32, x::signed-32>>, state),
    do: %{state | have: MapSet.delete(state.have, {x, z})}

  defp handle("chunk_batch_finished", _, state),
    do: %{
      state
      | client: send_packet(state.client, :play, "chunk_batch_received", <<64.0::float-32>>)
    }

  defp handle("keep_alive", body, state),
    do: %{state | client: send_packet(state.client, :play, "keep_alive", body)}

  defp handle("player_position", body, state) do
    {teleport,
     <<x::float-64, y::float-64, z::float-64, _::binary-size(24), yaw::float-32, pitch::float-32,
       _::32>>} = Wire.take_varint(body)

    client =
      send_packet(state.client, :play, "accept_teleportation", [
        Wire.varint(teleport),
        <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32>>
      ])

    %{state | client: client, position: {x, y, z}}
  end

  # Death: respawn at once (`client_command` 0), then load in again.
  defp handle("set_health", <<health::float-32, _::binary>>, state) when health <= 0.0 do
    client = send_packet(state.client, :play, "client_command", Wire.varint(0))
    %{state | client: client, deaths: state.deaths + 1}
  end

  defp handle("respawn", _, state),
    do: %{state | client: send_packet(state.client, :play, "player_loaded", <<>>)}

  defp handle("disconnect", body, _state), do: raise("disconnected: #{inspect(body, limit: 200)}")
  defp handle(_, _, state), do: state

  defp send_packet(client, phase, name, payload) do
    frame = Wire.frame(Data.id(phase, :serverbound, name), payload, client.threshold)
    :ok = :gen_tcp.send(client.socket, frame)
    client
  end

  defp read(client, timeout) do
    case Wire.next_frame(client.buffer, 2_097_152, client.threshold) do
      {:ok, id, body, rest} ->
        {id, body, %{client | buffer: rest}}

      :more ->
        case :gen_tcp.recv(client.socket, 0, timeout) do
          {:ok, bytes} -> read(%{client | buffer: client.buffer <> bytes}, timeout)
          {:error, :timeout} -> {:timeout, client}
          error -> raise "socket #{inspect(error)}"
        end
    end
  end

  defp await(client, phase, name) do
    case read(client, 30_000) do
      {:timeout, _} ->
        raise "no #{name}"

      {id, body, client} ->
        if Data.name(phase, :clientbound, id) == name,
          do: {body, client},
          else: await(client, phase, name)
    end
  end

  ## The server side.

  def player do
    Enum.find(Valimc.Player.PlayerList.all(), &(&1.name == @name))
  end

  def await_player(deadline) do
    cond do
      player = player() -> player
      now_ms() > deadline -> raise "player did not join"
      true -> Process.sleep(20) && await_player(deadline)
    end
  end

  def client_report(client) do
    send(client, {:report, self()})

    receive do
      {:client, report} -> report
    after
      5000 -> raise "client stalled"
    end
  end

  # Wait until the client has its whole view and generation is idle.
  def await_view(client, deadline) do
    report = client_report(client)

    view =
      case report.position do
        {x, _, z} ->
          length(Valimc.Player.ChunkView.chunks({{floor(x / 16), floor(z / 16)}, @distance}))

        nil ->
          :infinity
      end

    cond do
      report.loaded >= view and wanted() == 0 ->
        report

      now_ms() > deadline ->
        raise "view not loaded: #{report.loaded}/#{view} chunks"

      true ->
        Process.sleep(1000)
        await_view(client, deadline)
    end
  end

  defp wanted do
    case :ets.lookup(Valimc.Data.Metrics, :worldgen_wanted_overworld) do
      [{_, cell}] -> :counters.get(cell, 1)
      [] -> 0
    end
  end

  def op(connection, op) do
    deadline = now_ms() + 10_000
    {:ok, _} = GenServer.call(connection, {:command_op, op, deadline}, 10_000)
  end

  # One sample a second: the hosting owner, every owner's totals and the
  # host's heap.
  def sample(uuid) do
    host = Valimc.Player.Storage.host(uuid)

    heap =
      case host && Process.info(host, [:total_heap_size, :message_queue_len]) do
        [total_heap_size: words, message_queue_len: queue] -> {words * 8, queue}
        _ -> {0, 0}
      end

    %{at: now_ms(), host: host, totals: ProfileWork.snapshot(), heap: heap}
  end

  def measure(uuid, seconds) do
    first = sample(uuid)
    # `:scheduler` (runtime_tools) is not on a pruned Mix code path.
    :erlang.system_flag(:scheduler_wall_time, true)
    schedulers = :erlang.statistics(:scheduler_wall_time_all)

    samples =
      for _ <- 1..seconds, reduce: [first] do
        acc ->
          Process.sleep(max(0, hd(acc).at + 1000 - now_ms()))
          [sample(uuid) | acc]
      end
      |> Enum.reverse()

    {samples, utilization(schedulers, :erlang.statistics(:scheduler_wall_time_all))}
  end

  # `{type, id, share, _}` per scheduler, as `:scheduler.utilization/2`.
  defp utilization(first, last) do
    normal = :erlang.system_info(:schedulers)
    dirty = :erlang.system_info(:dirty_cpu_schedulers)
    old = Map.new(first, fn {id, active, total} -> {id, {active, total}} end)

    type = fn id ->
      if id <= normal, do: :normal, else: if(id <= normal + dirty, do: :cpu, else: :io)
    end

    for {id, active, total} <- Enum.sort(last),
        {a0, t0} = old[id],
        do: {type.(id), id, if(total > t0, do: (active - a0) / (total - t0), else: 0.0), nil}
  end

  def summarize(samples, utilization) do
    hosts = samples |> Enum.map(& &1.host) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    first = hd(samples)
    last = List.last(samples)
    elapsed = (last.at - first.at) / 1000

    # Completed ticks of the hosting owner per one-second interval.
    tps =
      for [a, b] <- Enum.chunk_every(samples, 2, 1, :discard),
          a.host != nil and a.host == b.host,
          old = a.totals[a.host],
          new = b.totals[b.host],
          old != nil and new != nil,
          do: (new.completed_ticks - old.completed_ticks) * 1000 / (b.at - a.at)

    callbacks =
      for kind <- [
            :tick,
            :commit,
            :player,
            :generation,
            :light,
            :transfer,
            :call,
            :resource,
            :gc,
            :load,
            :other
          ],
          into: %{} do
        {calls, ns, buckets} =
          Enum.reduce(hosts, {0, 0, nil}, fn pid, {calls, ns, buckets} ->
            new = get_in(last.totals, [pid, :callbacks, kind])
            old = get_in(first.totals, [pid, :callbacks, kind])

            case new do
              nil ->
                {calls, ns, buckets}

              new ->
                old = old || %{calls: 0, ns: 0, buckets: nil}
                delta = bucket_delta(new[:buckets], old[:buckets])
                {calls + new.calls - old.calls, ns + new.ns - old.ns, bucket_sum(buckets, delta)}
            end
          end)

        stats =
          Map.merge(
            %{
              calls: calls,
              total_ms: Float.round(ns / 1.0e6, 1),
              per_minute_ms: Float.round(ns / 1.0e6 * 60 / elapsed, 1),
              mean_ms: if(calls > 0, do: Float.round(ns / calls / 1.0e6, 3)),
              max_bucket_ms: max_bucket(buckets)
            },
            ProfileWork.percentiles(buckets)
          )

        {kind, stats}
      end

    phases =
      Enum.reduce(hosts, %{}, fn pid, acc ->
        new = get_in(last.totals, [pid, :phases]) || %{}
        old = get_in(first.totals, [pid, :phases]) || %{}

        Enum.reduce(new, acc, fn {phase, stats}, acc ->
          ns = stats.ns - (get_in(old, [phase, :ns]) || 0)
          Map.update(acc, phase, ns, &(&1 + ns))
        end)
      end)

    sampled =
      Enum.sum(
        for pid <- hosts,
            new = last.totals[pid],
            new != nil,
            do: new.sampled_ticks - (first.totals[pid] || %{sampled_ticks: 0}).sampled_ticks
      )

    %{
      seconds: elapsed,
      host_changes: length(hosts) - 1,
      tps: %{
        mean: mean(tps),
        min: if(tps != [], do: Float.round(Enum.min(tps), 2)),
        intervals: length(tps)
      },
      callbacks: callbacks,
      sampled_ticks: sampled,
      phase_mean_ms:
        if(sampled > 0,
          do: Map.new(phases, fn {k, ns} -> {k, Float.round(ns / sampled / 1.0e6, 3)} end)
        ),
      heap_max_mib: Float.round(Enum.max(Enum.map(samples, &elem(&1.heap, 0))) / 1_048_576, 1),
      heap_last_mib: Float.round(elem(last.heap, 0) / 1_048_576, 1),
      mailbox_max: Enum.max(Enum.map(samples, &elem(&1.heap, 1))),
      workload: last.host && get_in(last.totals, [last.host, :workload]),
      # Mean utilization (%) of the normal and dirty CPU schedulers.
      schedulers:
        for {type, id, value, _} <- utilization,
            type in [:normal, :cpu],
            reduce: %{} do
          acc ->
            name = if type == :cpu, do: :dirty_cpu, else: :normal
            Map.update(acc, name, [{id, value}], &[{id, value} | &1])
        end
        |> Map.new(fn {type, list} ->
          {type, Float.round(Enum.sum(Enum.map(list, &elem(&1, 1))) * 100 / length(list), 1)}
        end)
    }
  end

  # `HEAP=1`: words each field of the host's section states holds, summed
  # over sections, flat (shared subterms count every time they are reached).
  def heap(uuid) do
    with pid when is_pid(pid) <- Valimc.Player.Storage.host(uuid) do
      state = :sys.get_state(pid, 60_000)

      fields =
        for {_, section} <- state.sections,
            {field, value} <- Map.from_struct(section.resource),
            reduce: %{} do
          acc ->
            Map.update(
              acc,
              field,
              :erts_debug.flat_size(value),
              &(&1 + :erts_debug.flat_size(value))
            )
        end

      entities =
        for {_, section} <- state.sections,
            {field, value} <- Map.to_list(section.resource.entities),
            reduce: %{} do
          acc ->
            Map.update(
              acc,
              field,
              :erts_debug.flat_size(value),
              &(&1 + :erts_debug.flat_size(value))
            )
        end

      mib = fn words -> Float.round(words * 8 / 1_048_576, 2) end

      top = fn map ->
        map
        |> Enum.sort_by(&(-elem(&1, 1)))
        |> Enum.take(15)
        |> Map.new(fn {k, w} -> {k, mib.(w)} end)
      end

      %{
        sections: map_size(state.sections),
        state_mib: mib.(:erts_debug.flat_size(state)),
        section_fields_mib: top.(fields),
        entity_fields_mib: top.(entities)
      }
    end
  end

  def trace_memory(uuid) do
    owner = Valimc.Player.Storage.host(uuid)

    modules =
      for {module, _} <- :code.all_loaded(),
          String.starts_with?(Atom.to_string(module), [
            "Elixir.Valimc.",
            "Elixir.Enum",
            "Elixir.Map"
          ]),
          do: module

    for module <- modules,
        do: :erlang.trace_pattern({module, :_, :_}, true, [:local, :call_memory])

    :erlang.trace(owner, true, [:call])
    {owner, modules}
  end

  def memory_report({owner, modules}) do
    :erlang.trace(owner, false, [:call])

    rows =
      for module <- modules,
          {name, arity} <- module.module_info(:functions),
          {:call_memory, entries} <- [:erlang.trace_info({module, name, arity}, :call_memory)],
          is_list(entries),
          {pid, calls, words} <- entries,
          pid == owner,
          do: {"#{inspect(module)}.#{name}/#{arity}", calls, words}

    for module <- modules,
        do: :erlang.trace_pattern({module, :_, :_}, false, [:local, :call_memory])

    total = rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()

    %{
      total_mib: Float.round(total * 8 / 1_048_576, 1),
      top:
        rows
        |> Enum.sort_by(&(-elem(&1, 2)))
        |> Enum.take(60)
        |> Enum.map(fn {f, calls, words} ->
          %{function: f, calls: calls, mib: Float.round(words * 8 / 1_048_576, 2)}
        end)
    }
  end

  def trace_gc(uuid) do
    owner = Valimc.Player.Storage.host(uuid)
    parent = self()

    tracer =
      spawn(fn ->
        :erlang.trace(owner, true, [:garbage_collection, :monotonic_timestamp])
        send(parent, :tracing)
        gc_loop(%{})
      end)

    receive do
      :tracing -> tracer
    end
  end

  defp gc_loop(acc) do
    receive do
      {:trace_ts, _, start, info, at} when start in [:gc_minor_start, :gc_major_start] ->
        gc_loop(Map.put(acc, :open, {start, at, info[:heap_size], info[:old_heap_size]}))

      {:trace_ts, _, done, _info, at} when done in [:gc_minor_end, :gc_major_end] ->
        case acc[:open] do
          {start, from, heap, old} ->
            us = :erlang.convert_time_unit(at - from, :native, :microsecond)
            kind = if start == :gc_minor_start, do: :minor, else: :major

            row =
              Map.get(acc, kind, %{
                count: 0,
                total_ms: 0.0,
                max_ms: 0.0,
                heap_words: 0,
                old_words: 0
              })

            row = %{
              row
              | count: row.count + 1,
                total_ms: row.total_ms + us / 1000,
                max_ms: max(row.max_ms, us / 1000),
                heap_words: max(row.heap_words, heap || 0),
                old_words: max(row.old_words, old || 0)
            }

            gc_loop(acc |> Map.delete(:open) |> Map.put(kind, row))

          _ ->
            gc_loop(acc)
        end

      {:report, from} ->
        send(from, {:gc, Map.delete(acc, :open)})

      _ ->
        gc_loop(acc)
    end
  end

  def gc_report(tracer) do
    send(tracer, {:report, self()})

    receive do
      {:gc, report} -> report
    after
      5000 -> nil
    end
  end

  # The host's last sampled ticks, oldest first, with their phases.
  def recent(%{host: host, totals: totals}) do
    rows = Map.get(totals[host] || %{}, :recent, [])

    for {ms, phases} <- Enum.reverse(rows) do
      %{ms: Float.round(ms, 2), phases: Map.new(phases, fn {k, v} -> {k, Float.round(v, 2)} end)}
    end
  end

  defp bucket_delta(nil, _), do: nil
  defp bucket_delta(new, nil), do: new

  defp bucket_delta(new, old),
    do: List.to_tuple(Enum.zip_with(Tuple.to_list(new), Tuple.to_list(old), &(&1 - &2)))

  defp bucket_sum(nil, b), do: b
  defp bucket_sum(a, nil), do: a

  defp bucket_sum(a, b),
    do: List.to_tuple(Enum.zip_with(Tuple.to_list(a), Tuple.to_list(b), &(&1 + &2)))

  # The upper bound of the highest bucket any callback fell into (nil: none
  # or above the last bound).
  @bounds [0.25, 0.5, 1, 2, 3, 5, 7.5, 10, 15, 20, 30, 50, 75, 100, 150, 250, 500, 1000, nil]
  defp max_bucket(nil), do: nil

  defp max_bucket(buckets) do
    buckets
    |> Tuple.to_list()
    |> Enum.zip(@bounds)
    |> Enum.filter(fn {n, _} -> n > 0 end)
    |> List.last()
    |> case do
      nil -> nil
      {_, bound} -> bound || :over_1000
    end
  end

  defp mean([]), do: nil
  defp mean(list), do: Float.round(Enum.sum(list) / length(list), 2)

  def now_ms, do: System.monotonic_time(:millisecond)
end

alias Bench.TickBudget

case System.argv() do
  ["prepare", template] ->
    # An existing template is reopened: its view finishes loading and saves.
    template = Path.expand(template)
    File.mkdir_p!(template)
    TickBudget.configure(template)
    parent = self()
    client = spawn_link(fn -> TickBudget.join(parent) end)
    TickBudget.await_player(TickBudget.now_ms() + 60_000)
    report = TickBudget.await_view(client, TickBudget.now_ms() + 3_600_000)
    IO.puts("template view: #{report.chunks} chunks at #{inspect(report.position)}")
    # Let the last columns adopt and commit before the world stops.
    Process.sleep(10_000)
    Process.unlink(client)
    Process.exit(client, :kill)
    Application.stop(:valimc)

  ["run", template, output, scenario | rest] when scenario in ["combat", "explore"] ->
    seconds = String.to_integer(List.first(rest) || "60")
    true = seconds in 10..600
    world = Path.expand(".local/tick-budget/runs/#{scenario}-#{System.os_time(:second)}")
    File.mkdir_p!(Path.dirname(world))
    {_, 0} = System.cmd("cp", ["-cR", Path.expand(template), world])
    TickBudget.configure(world)
    parent = self()
    started = TickBudget.now_ms()
    client = spawn_link(fn -> TickBudget.join(parent) end)
    player = TickBudget.await_player(started + 60_000)
    view = TickBudget.await_view(client, started + 600_000)
    loaded_ms = TickBudget.now_ms() - started
    IO.puts("view of #{view.chunks} chunks loaded in #{loaded_ms} ms")

    warmup =
      case scenario do
        "combat" ->
          :ok = Valimc.World.Clock.configure({"minecraft:overworld", :paused, true})
          :ok = Valimc.World.Clock.configure({"minecraft:overworld", :ticks, 18_000})
          :ok = Valimc.World.Clock.flush()
          60

        "explore" ->
          TickBudget.op(player.pid, {:game_mode, :spectator, nil})
          {x, _, z} = view.position
          TickBudget.op(player.pid, {:teleport, %{x: x, y: 160.0, z: z, yaw: 0.0, pitch: 0.0}})
          Process.sleep(2000)
          send(client, {:fly, 20.0})
          5
      end

    warmup = String.to_integer(System.get_env("WARMUP", Integer.to_string(warmup)))
    Process.sleep(warmup * 1000)
    before = TickBudget.client_report(client)
    # `PROFILE=stacks` also takes a built-in profile of the measured window
    # (the same report as a player's capture; sampling adds its own cost).
    profiling = System.get_env("PROFILE") == "stacks"

    if profiling do
      Application.put_env(:valimc, :profiler_path, Path.dirname(Path.expand(output)))
      options = %{timeout: seconds + 30, interval: 20, process: "*", include_waiting: false}
      {:ok, _} = Valimc.Admin.Profiler.start(options)
    end

    # `GCTRACE=1`: the host owner's collections over the window (count, total
    # and longest wall time per kind, and heap sizes before them).
    gc_tracer = if System.get_env("GCTRACE") == "1", do: TickBudget.trace_gc(player.uuid)
    # `PROFILE=memory`: words each function of the host owner allocates
    # (exclusive of callees, `call_memory` tracing; it slows the owner).
    memory = if System.get_env("PROFILE") == "memory", do: TickBudget.trace_memory(player.uuid)
    {samples, utilization} = TickBudget.measure(player.uuid, seconds)
    allocations = if memory, do: TickBudget.memory_report(memory)
    gc = if gc_tracer, do: TickBudget.gc_report(gc_tracer)
    profile = if profiling, do: elem(Valimc.Admin.Profiler.stop(), 1)
    after_run = TickBudget.client_report(client)
    heap = if System.get_env("HEAP") == "1", do: TickBudget.heap(player.uuid)

    # The last 100 complete ticks in order (all owners' ring, one owner here),
    # to see periodic spikes.
    {ring, _} = Valimc.World.TickRate.samples()
    [{:slot, slot}] = :ets.lookup(Valimc.World.TickRate, :slot)
    {newer, older} = Enum.split(ring, slot + 1)
    last_ticks = for ns <- older ++ newer, ns > 0, do: Float.round(ns / 1.0e6, 2)
    {revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {dirty, 0} = System.cmd("git", ["status", "--porcelain", "--untracked-files=no"])

    result =
      Map.merge(TickBudget.summarize(samples, utilization), %{
        scenario: scenario,
        revision: String.trim(revision),
        dirty_tree: dirty != "",
        mix_env: Mix.env(),
        otp: List.to_string(:erlang.system_info(:otp_release)),
        schedulers_online: :erlang.system_info(:schedulers_online),
        dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
        view_loaded_ms: loaded_ms,
        profile: profile,
        heap_breakdown: heap,
        last_ticks_ms: last_ticks,
        gc_trace: gc,
        allocations: allocations,
        recent_sampled: TickBudget.recent(List.last(samples)),
        warmup_s: warmup,
        client: %{
          deaths: after_run.deaths - before.deaths,
          chunks_received: after_run.chunks - before.chunks,
          own_chunk_missing_ms: after_run.missing_ms - before.missing_ms,
          moved_blocks:
            if(before.position && after_run.position,
              do: Float.round(elem(after_run.position, 0) - elem(before.position, 0), 1)
            )
        },
        harness_sha256:
          :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower)
      })

    File.mkdir_p!(Path.dirname(Path.expand(output)))
    File.write!(output, JSON.encode!(result))

    IO.inspect(
      Map.take(result, [
        :tps,
        :callbacks,
        :phase_mean_ms,
        :heap_max_mib,
        :workload,
        :schedulers,
        :client,
        :heap_breakdown
      ]),
      label: "tick budget #{scenario}",
      limit: :infinity
    )

    Process.unlink(client)
    Process.exit(client, :kill)
    Application.stop(:valimc)
    File.rm_rf!(world)

  _ ->
    raise "usage: prepare TEMPLATE | run TEMPLATE OUTPUT combat|explore [SECONDS]"
end
