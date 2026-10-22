# Run only when the user explicitly asks for it (AGENTS.md): it takes far too
# long to be a check or a gate.
#
# A player outrunning generation (VMC-077u). One real loopback TCP client in
# spectator mode flies straight over terrain nothing has generated, at a
# spectator's top speed with a large view distance, acknowledging every chunk
# batch at 64 chunks per tick. It reports how long each chunk the player flew
# into was missing on the client (the vanilla client renders nothing while
# the camera's chunk is absent), how busy the generation pool was while
# chunks were wanted, and the dirty schedulers' utilization.
#
#   VALIMC_GENERATOR=vanilla VALIMC_SEED=20261020 VALIMC_WORLD=<fresh dir> \
#     VALIMC_PORT=0 VALIMC_VIEW_DISTANCE=32 MIX_ENV=bench \
#     mix run bench/outrun_flight.exs bench/results/outrun.json [seconds] [blocks_per_second] \
#     [heading_degrees]
#
# The heading is measured from +X towards +Z; the default, 115 degrees, is the
# direction of the live run that found the problem (a diagonal, so each chunk
# crossed brings two strips of new chunks).
#
# `OUTRUN_SAMPLE` adds samplers (comma separated, VMC-077w): `groups` records
# every region group every 2 s (sections, reductions, mailbox, memory) and how
# often the largest is running or runnable (every 10 ms); `stacks` prints
# where the largest group spends its busy time (its stack every 2 ms);
# `scheduler_stacks` the same for the generation scheduler; `waits` what the
# player's chunk waits for in the scheduler while it is missing (VMC-077x).
alias Valimc.Protocol.{Data, Wire}
alias Valimc.Worldgen.Pool

[output | rest] = System.argv()
seconds = String.to_integer(Enum.at(rest, 0, "40"))
speed = String.to_float(Enum.at(rest, 1, "58.0"))
heading = String.to_float(Enum.at(rest, 2, "115.0")) * :math.pi() / 180
distance = 32
%{generator: :vanilla, seed: seed} = Valimc.World.Spec.current()
now = fn -> System.monotonic_time(:microsecond) end
world = Valimc.config(:world_path)

defmodule Bench.Client do
  alias Valimc.Protocol.{Data, Wire}

  def send(client, phase, name, payload) do
    :ok =
      :gen_tcp.send(
        client.socket,
        Wire.frame(Data.id(phase, :serverbound, name), payload, client.threshold)
      )

    client
  end

  # The next frame, or `:timeout` once `timeout` ms passed without one.
  def read(client, timeout) do
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

  def await(client, phase, name) do
    case read(client, 30_000) do
      {:timeout, _} ->
        raise "no #{name}"

      {id, body, client} ->
        if Data.name(phase, :clientbound, id) == name,
          do: {body, client},
          else: await(client, phase, name)
    end
  end
end

alias Bench.Client

{:ok, socket} =
  :gen_tcp.connect({127, 0, 0, 1}, Valimc.Net.Listener.port(), [:binary, active: false], 5000)

name = "OutrunBench"
client = %{socket: socket, buffer: <<>>, threshold: nil}

client =
  client
  |> Client.send(:handshake, "intention", [
    Wire.varint(777),
    Wire.string("localhost"),
    <<25565::16, 2>>
  ])
  |> Client.send(:login, "hello", [Wire.string(name), <<0::128>>])

{body, client} = Client.await(client, :login, "login_compression")
{threshold, <<>>} = Wire.take_varint(body)
client = %{client | threshold: threshold}
{_, client} = Client.await(client, :login, "login_finished")
client = Client.send(client, :login, "login_acknowledged", <<>>)
{packs, client} = Client.await(client, :configuration, "select_known_packs")

client =
  client
  |> Client.send(:configuration, "client_information", [
    Wire.string("en_us"),
    <<distance::signed-8, 0, 1, 0x7F, 1, 0, 1, 0>>
  ])
  |> Client.send(:configuration, "select_known_packs", packs)

{_, client} = Client.await(client, :configuration, "finish_configuration")
client = Client.send(client, :configuration, "finish_configuration", <<>>)
{_, client} = Client.await(client, :play, "login")

pid =
  Enum.find_value(1..1000, fn _ ->
    Enum.find_value(Valimc.Player.PlayerList.all(), &if(&1.name == name, do: &1.pid)) ||
      (Process.sleep(5) && nil)
  end) || raise "player did not register"

Process.monitor(pid)

op = fn op ->
  deadline = System.monotonic_time(:millisecond) + 10_000
  {:ok, _} = GenServer.call(pid, {:command_op, op, deadline}, 10_000)
end

# One frame: chunks received and forgotten, batches acknowledged, keep-alives
# and teleports answered. `:timeout` when none came within `timeout` ms.
handle = fn client, have, timeout ->
  case Client.read(client, timeout) do
    {:timeout, client} ->
      {:timeout, client, have}

    {id, body, client} ->
      case {Data.name(:play, :clientbound, id), body} do
        {"level_chunk_with_light", <<x::signed-32, z::signed-32, _::binary>>} ->
          # Every arrival, kept after the view forgets the chunk.
          at = now.()
          Process.put({:arrived, {x, z}}, [at | Process.get({:arrived, {x, z}}, [])])
          {{:chunk, {x, z}}, client, Map.put(have, {x, z}, at)}

        {"forget_level_chunk", <<z::signed-32, x::signed-32>>} ->
          {:ok, client, Map.delete(have, {x, z})}

        {"chunk_batch_finished", _} ->
          {:ok, Client.send(client, :play, "chunk_batch_received", <<64.0::float-32>>), have}

        {"disconnect", body} ->
          raise "disconnected: #{inspect(body, limit: 200)}"

        {"keep_alive", body} ->
          {:ok, Client.send(client, :play, "keep_alive", body), have}

        {"player_position", body} ->
          {teleport,
           <<x::float-64, y::float-64, z::float-64, _::binary-size(24), yaw::float-32,
             pitch::float-32, _::32>>} = Wire.take_varint(body)

          client =
            Client.send(client, :play, "accept_teleportation", [
              Wire.varint(teleport),
              <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32>>
            ])

          {{:teleport, {x, y, z}}, client, have}

        _ ->
          {:ok, client, have}
      end
  end
end

# Read until `done?.(have)` or `ms` pass.
settle = fn settle, client, have, done?, deadline ->
  if done?.(have) or now.() > deadline do
    {client, have}
  else
    {_, client, have} = handle.(client, have, 50)
    settle.(settle, client, have, done?, deadline)
  end
end

chunk_of = fn x, z -> {floor(x / 16), floor(z / 16)} end

# Join, take the spawn teleport, become a spectator high above the spawn and
# wait until its view is there.
{client, have} =
  settle.(settle, client, %{}, fn _ -> false end, now.() + 1_000_000)

client = Client.send(client, :play, "player_loaded", <<>>)
start = :sys.get_state(pid).player
op.({:game_mode, :spectator, nil})
y = 160.0
op.({:teleport, %{x: start.x, y: y, z: start.z, yaw: 0.0, pitch: 0.0}})

view =
  MapSet.new(Valimc.Player.ChunkView.chunks({chunk_of.(start.x, start.z), distance}))

{client, have} =
  settle.(
    settle,
    client,
    have,
    &Enum.all?(view, fn c -> Map.has_key?(&1, c) end),
    now.() + 300_000_000
  )

IO.puts("spawn view of #{MapSet.size(view)} chunks loaded; flying for #{seconds} s")

# Samplers: generation pool occupancy every 5 ms, wanted chunks every 250 ms,
# dirty scheduler utilization every second.
bench = self()

# The overworld's generation scheduler, and whether it is running or
# runnable (busy) at a sample.
[{scheduler, _}] = Registry.lookup(Valimc.Worldgen.Schedulers, {world, :overworld})

# Chunks the scheduler has wanted and not sent yet (its gauge).
wanted = fn ->
  case :ets.lookup(Valimc.Data.Metrics, :worldgen_wanted_overworld) do
    [{_, cell}] -> :counters.get(cell, 1)
    [] -> 0
  end
end

pool_sampler =
  spawn_link(fn ->
    loop = fn loop, samples ->
      receive do
        :stop ->
          send(bench, {:pool, Enum.reverse(samples)})
      after
        5 ->
          status = elem(Process.info(scheduler, :status), 1)

          sample =
            {now.(), Pool.size() - Pool.free(), status in [:running, :runnable], wanted.()}

          loop.(loop, [sample | samples])
      end
    end

    loop.(loop, [])
  end)

# The largest mailbox of a region group (their tickets wait behind it), what
# that group runs and its heap (words).
mailbox = fn ->
  Process.list()
  |> Enum.flat_map(fn p ->
    case Process.info(p, [:message_queue_len, :dictionary]) do
      [message_queue_len: n, dictionary: d] ->
        if d[:"$initial_call"] == {Valimc.World.Region, :init, 1}, do: [{n, p}], else: []

      nil ->
        []
    end
  end)
  |> Enum.max(fn -> {0, nil} end)
  |> then(fn
    {n, nil} ->
      [n, nil, 0]

    {n, p} ->
      case Process.info(p, [:current_stacktrace, :total_heap_size]) do
        [current_stacktrace: stack, total_heap_size: heap] ->
          [n, stack |> Enum.take(4) |> Enum.map(&inspect(Tuple.delete_at(&1, 3))), heap]

        nil ->
          [n, nil, 0]
      end
  end)
end

wants_sampler =
  spawn_link(fn ->
    loop = fn loop, samples ->
      receive do
        :stop ->
          send(bench, {:wants, Enum.reverse(samples)})
      after
        250 ->
          stats = Valimc.Worldgen.Scheduler.stats(world, :overworld)
          loop.(loop, [{now.(), stats.wanted, stats.running, mailbox.()} | samples])
      end
    end

    loop.(loop, [])
  end)

# Scheduler wall time: normal schedulers come first, then the dirty CPU ones.
:erlang.system_flag(:scheduler_wall_time, true)
normal_count = System.schedulers()
dirty_count = :erlang.system_info(:dirty_cpu_schedulers)

wall = fn ->
  :erlang.statistics(:scheduler_wall_time_all)
  |> Enum.sort()
  |> Enum.take(normal_count + dirty_count)
end

utilization = fn before, after_ ->
  shares =
    Enum.zip_with(before, after_, fn {id, a0, t0}, {id, a1, t1} ->
      {id, if(t1 > t0, do: (a1 - a0) / (t1 - t0), else: 0.0)}
    end)

  {normal, dirty} = Enum.split_with(shares, fn {id, _} -> id <= normal_count end)
  share = fn list -> Enum.sum(Enum.map(list, &elem(&1, 1))) / max(length(list), 1) end
  {share.(normal), share.(dirty)}
end

util_sampler =
  spawn_link(fn ->
    loop = fn loop, last, samples ->
      receive do
        :stop ->
          send(bench, {:util, Enum.reverse(samples)})
      after
        1000 ->
          sample = wall.()
          {normal, dirty} = utilization.(last, sample)
          loop.(loop, sample, [{now.(), normal, dirty} | samples])
      end
    end

    loop.(loop, wall.(), [])
  end)

sample = String.split(System.get_env("OUTRUN_SAMPLE", ""), ",", trim: true)

# A mailbox message's kind.
tag = fn
  {:resource, _, inner} when is_tuple(inner) -> {:resource, elem(inner, 0)}
  {:"$gen_call", _, request} when is_tuple(request) -> {:call, elem(request, 0)}
  {:"$gen_call", _, request} -> {:call, request}
  {:"$gen_cast", request} when is_tuple(request) -> {:cast, elem(request, 0)}
  message when is_tuple(message) -> elem(message, 0)
  message -> message
end

# Every group every 2 s: `{t, [{sections, reductions since the last row,
# mailbox, memory bytes}]}` largest first, the largest group's busy share
# (running or runnable at a 10 ms sample) over those 2 s, and what its mailbox
# holds when it holds more than 50 messages.
group_sampler =
  if "groups" in sample do
    spawn_link(fn ->
      row = fn ->
        for {pid, keys} <- Valimc.World.Regionizer.groups(:overworld),
            info = Process.info(pid, [:reductions, :message_queue_len, :memory]),
            info != nil,
            do: {pid, length(keys), info}
      end

      loop = fn loop, rows, last, largest, busy, n ->
        receive do
          :stop ->
            send(bench, {:groups, Enum.reverse(rows)})
        after
          10 ->
            busy =
              case largest && Process.info(largest, :status) do
                {:status, status} when status in [:running, :runnable] -> busy + 1
                _ -> busy
              end

            if n < 200 do
              loop.(loop, rows, last, largest, busy, n + 1)
            else
              groups = row.()

              entries =
                groups
                |> Enum.map(fn {pid, sections, info} ->
                  {sections, info[:reductions] - Map.get(last, pid, info[:reductions]),
                   info[:message_queue_len], info[:memory], pid}
                end)
                |> Enum.sort(:desc)

              largest = with [{_, _, _, _, pid} | _] <- entries, do: pid, else: (_ -> nil)

              tags =
                with [{_, _, queue, _, pid} | _] when queue > 50 <- entries,
                     {:messages, messages} <- Process.info(pid, :messages) do
                  messages
                  |> Enum.frequencies_by(&inspect(tag.(&1)))
                  |> Enum.sort_by(&(-elem(&1, 1)))
                  |> Enum.take(6)
                  |> Map.new()
                else
                  _ -> %{}
                end

              entries = Enum.map(entries, &Tuple.delete_at(&1, 4))
              last = Map.new(groups, fn {pid, _, info} -> {pid, info[:reductions]} end)
              rows = [{now.(), entries, busy / n, tags} | rows]
              loop.(loop, rows, last, largest, 0, 1)
            end
        end
      end

      loop.(loop, [], %{}, nil, 0, 200)
    end)
  end

# The largest group's (or the scheduler's) stack every 2 ms: frames counted
# once per busy sample.
stack_sampler =
  if "stacks" in sample or "scheduler_stacks" in sample do
    spawn_link(fn ->
      largest = fn ->
        if "scheduler_stacks" in sample,
          do: scheduler,
          else:
            Valimc.World.Regionizer.groups(:overworld)
            |> Enum.max_by(fn {_, keys} -> length(keys) end, fn -> {nil, []} end)
            |> elem(0)
      end

      loop = fn loop, counts, target, n ->
        receive do
          :stop ->
            send(bench, {:stacks, counts, n})
        after
          2 ->
            target = if rem(n, 500) == 0 or target == nil, do: largest.(), else: target

            counts =
              case target && Process.info(target, [:current_stacktrace, :status]) do
                [current_stacktrace: stack, status: status]
                when status in [:running, :runnable] ->
                  stack
                  |> Enum.map(fn {m, f, a, _} -> {m, f, a} end)
                  |> Enum.uniq()
                  |> Enum.reduce(Map.update(counts, :busy, 1, &(&1 + 1)), fn frame, acc ->
                    Map.update(acc, frame, 1, &(&1 + 1))
                  end)

                _ ->
                  counts
              end

            loop.(loop, counts, target, n + 1)
        end
      end

      loop.(loop, %{}, nil, 0)
    end)
  end

# The chunk the player is in and since when it is missing (ms, 0: there).
here = :atomics.new(3, signed: true)

# While the player's chunk has been missing for over a second, every 500 ms
# (VMC-077x): what it waits for in the scheduler. The undecorated chunks of
# its 3 × 3 and, transitively, the earlier decorations they wait for
# (`chain`); of those, how many could run now and the terrain they lack; how
# many goals rank before it; and the pool and the queues (VMC-077x1).
waits_sampler =
  if "waits" in sample do
    spawn_link(fn ->
      around = &Valimc.Worldgen.Frontier.around/2

      chain = fn chain, f, todo, seen ->
        case todo do
          [] ->
            seen

          [n | rest] ->
            new = f.deps[n].waits |> Enum.reject(&MapSet.member?(seen, &1))
            chain.(chain, f, new ++ rest, Enum.into(new, seen))
        end
      end

      analyse = fn f, own ->
        start = for n <- around.(own, 1), Map.has_key?(f.deps, n), do: n
        decos = chain.(chain, f, start, MapSet.new(start))
        lacking = decos |> Enum.flat_map(&f.deps[&1].lacking) |> Enum.uniq()
        rank = f.ranks[own]

        %{
          own_status: get_in(f.chunks, [own, :status]),
          own_rank: rank,
          own_seq: f.seqs[own],
          goals_before: if(rank, do: Enum.count(f.ranks, fn {_, r} -> r < rank end)),
          chain: MapSet.size(decos),
          chain_ready: Enum.count(decos, &MapSet.member?(f.ready, &1)),
          chain_running: Enum.count(decos, &Map.has_key?(f.busy, &1)),
          chain_unneeded: Enum.count(decos, &(f.deps[&1].need == 0)),
          lacking_terrain: length(lacking),
          lacking_running: Enum.count(lacking, &Map.has_key?(f.busy, &1)),
          spilled: Enum.count(decos, &match?(%{cell: {:spilled, _, _}}, f.chunks[&1])),
          alone: MapSet.member?(f.alone, own),
          wanted: map_size(f.ranks),
          ready: MapSet.size(f.ready),
          terrain_needed: map_size(f.terrain),
          finals: MapSet.size(f.finals),
          jobs: f.jobs |> Map.values() |> Enum.frequencies_by(& &1.kind),
          in_memory: f.in_memory
        }
      end

      loop = fn loop, rows ->
        receive do
          :stop ->
            send(bench, {:waits, Enum.reverse(rows)})
        after
          500 ->
            since = :atomics.get(here, 3)
            t = div(now.(), 1000)

            rows =
              if since != 0 and t - since > 1000 do
                own = {:atomics.get(here, 1), :atomics.get(here, 2)}
                {:message_queue_len, mailbox} = Process.info(scheduler, :message_queue_len)
                state = :sys.get_state(scheduler, 10_000)
                row = analyse.(state.frontier, own)

                row =
                  Map.merge(row, %{
                    at: t,
                    chunk: Tuple.to_list(own),
                    missing_ms: t - since,
                    mailbox: mailbox,
                    pool: Pool.size() - Pool.free(),
                    # Groups without credit, and full chunks waiting for one.
                    outbox_blocked:
                      Enum.count(state.groups, fn {_, g} -> length(g.unacked) >= 2 end),
                    outbox_ready:
                      state.groups |> Enum.map(fn {_, g} -> map_size(g.ready) end) |> Enum.sum()
                  })

                IO.puts(
                  "waits #{inspect(Map.take(row, [:chunk, :missing_ms, :own_status, :own_rank, :goals_before, :chain, :chain_ready, :chain_running, :lacking_terrain, :lacking_running, :ready, :terrain_needed, :jobs, :pool]))}"
                )

                [row | rows]
              else
                rows
              end

            loop.(loop, rows)
        end
      end

      loop.(loop, [])
    end)
  end

counters =
  ~w(worldgen_chunks worldgen_microseconds worldgen_wants
     worldgen_dispatch_microseconds worldgen_terrain_jobs worldgen_decorate_jobs
     worldgen_full_jobs worldgen_alone_jobs chunks_encoded
     worldgen_terrain_microseconds worldgen_decorate_microseconds worldgen_full_microseconds
     worldgen_spills worldgen_drops worldgen_evict_microseconds)a

before = Valimc.Data.Metrics.snapshot()

# Fly: one position and one client tick end every 50 ms. Each chunk entered is
# recorded with the time it was entered; it is missing until it arrives. As
# the vanilla client (`LocalPlayer.tick` runs only while the level has the
# player's chunk), the player stands still while its chunk is missing, and a
# server teleport moves it.
step = speed / 20
{dx, dz} = {:math.cos(heading) * step, :math.sin(heading) * step}
started = now.()
ticks = seconds * 20

fly = fn fly, client, have, tick, pos, entered ->
  if tick > ticks do
    {client, have, pos, entered}
  else
    due = started + tick * 50_000
    left = div(due - now.(), 1000)

    if left > 0 do
      case handle.(client, have, left) do
        {{:teleport, {x, _, z}}, client, have} -> fly.(fly, client, have, tick, {x, z}, entered)
        {_, client, have} -> fly.(fly, client, have, tick, pos, entered)
      end
    else
      {x, z} = pos

      {client, {x, z}} =
        if Map.has_key?(have, chunk_of.(x, z)) do
          {x, z} = {x + dx, z + dz}

          {Client.send(
             client,
             :play,
             "move_player_pos",
             <<x::float-64, y::float-64, z::float-64, 0>>
           ), {x, z}}
        else
          {client, {x, z}}
        end

      client = Client.send(client, :play, "client_tick_end", <<>>)

      chunk = chunk_of.(x, z)

      entered =
        case entered do
          [{^chunk, _, _} | _] -> entered
          _ -> [{chunk, now.(), Map.get(have, chunk)} | entered]
        end

      :atomics.put(here, 1, elem(chunk, 0))
      :atomics.put(here, 2, elem(chunk, 1))

      case {Map.has_key?(have, chunk), :atomics.get(here, 3)} do
        {true, _} -> :atomics.put(here, 3, 0)
        {false, 0} -> :atomics.put(here, 3, div(elem(hd(entered), 1), 1000))
        _ -> :ok
      end

      fly.(fly, client, have, tick + 1, {x, z}, entered)
    end
  end
end

{client, have, {x, z}, entered} =
  fly.(fly, client, have, 1, {start.x, start.z}, [])

flown = now.()
:atomics.put(here, 3, 0)

# What fills the largest group mailbox at the end of the flight.
{_, largest} =
  Process.list()
  |> Enum.flat_map(fn p ->
    case Process.info(p, [:message_queue_len, :dictionary]) do
      [message_queue_len: n, dictionary: d] ->
        if d[:"$initial_call"] == {Valimc.World.Region, :init, 1}, do: [{n, p}], else: []

      nil ->
        []
    end
  end)
  |> Enum.max(fn -> {0, nil} end)

mailbox_tags =
  case largest && Process.info(largest, :messages) do
    {:messages, messages} ->
      messages |> Enum.frequencies_by(tag) |> Enum.sort_by(&(-elem(&1, 1))) |> Enum.take(12)

    _ ->
      []
  end

IO.puts("largest group mailbox: #{inspect(mailbox_tags)}")

# The last chunks entered may still be missing: wait for them a while.
{client, have} =
  settle.(
    settle,
    client,
    have,
    fn have -> Enum.all?(entered, fn {c, _, _} -> Map.has_key?(have, c) end) end,
    now.() + 30_000_000
  )

for sampler <- [pool_sampler, wants_sampler, util_sampler], do: send(sampler, :stop)
collect = fn tag -> receive do: ({^tag, samples} -> samples) end
pool = collect.(:pool)
wants = collect.(:wants)
util = collect.(:util)
if group_sampler, do: send(group_sampler, :stop)
if stack_sampler, do: send(stack_sampler, :stop)
groups = if group_sampler, do: collect.(:groups), else: []
if waits_sampler, do: send(waits_sampler, :stop)
waits = if waits_sampler, do: collect.(:waits), else: []

if stack_sampler do
  receive do
    {:stacks, counts, n} ->
      IO.puts("stacks: #{n} samples, #{counts[:busy]} busy")

      counts
      |> Map.delete(:busy)
      |> Enum.sort_by(&(-elem(&1, 1)))
      |> Enum.take(80)
      |> Enum.each(fn {frame, count} -> IO.puts("  #{count} #{inspect(frame)}") end)
  end
end

:gen_tcp.close(client.socket)

# Missing time per chunk entered: nothing when it was there at the moment of
# entering, else until it first arrived after that (or the end of the wait).
crossings =
  entered
  |> Enum.reverse()
  |> Enum.map(fn {chunk, at, there} ->
    arrived =
      Process.get({:arrived, chunk}, []) |> Enum.filter(&(&1 > at)) |> Enum.min(fn -> nil end)

    missing =
      cond do
        there != nil -> 0
        arrived != nil -> arrived - at
        true -> now.() - at
      end

    %{chunk: Tuple.to_list(chunk), entered_ms: div(at - started, 1000), missing_us: missing}
  end)

missing = crossings |> Enum.map(& &1.missing_us) |> Enum.sort()
pick = fn list, q -> Enum.at(list, min(length(list) - 1, floor(q * length(list)))) end
missed = Enum.count(missing, &(&1 > 0))

# Pool occupancy while chunks were wanted.
busy = for {t, n, _, w} <- pool, t <= flown, w > 0, do: n
pool_busy = if busy == [], do: 0.0, else: Enum.sum(busy) / length(busy) / Pool.size()
flying = for {t, _, s, _} <- pool, t <= flown, do: s
scheduler_busy = Enum.count(flying, & &1) / max(length(flying), 1)
dirty = for {t, _, d} <- util, t <= flown, do: d
normal = for {t, n, _} <- util, t <= flown, do: n
mean = fn list -> if list == [], do: 0.0, else: Enum.sum(list) / length(list) end

# The largest group at each 2 s row of the flight (VMC-077w).
largest_rows =
  for {t, [{sections, reductions, queue, memory} | _], busy, _} <- groups,
      t > started and t <= flown,
      do: %{
        sections: sections,
        reductions: reductions,
        mailbox: queue,
        memory: memory,
        busy: busy
      }

largest_group =
  if largest_rows == [] do
    nil
  else
    sorted = fn key -> largest_rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort() end

    %{
      reductions_per_second_median: div(pick.(sorted.(:reductions), 0.5), 2),
      reductions_per_second_max: div(List.last(sorted.(:reductions)), 2),
      mailbox_median: pick.(sorted.(:mailbox), 0.5),
      mailbox_max: List.last(sorted.(:mailbox)),
      busy_median: Float.round(pick.(sorted.(:busy), 0.5), 3),
      busy_mean: Float.round(mean.(sorted.(:busy)), 3),
      sections_max: List.last(sorted.(:sections)),
      memory_max_mb: div(List.last(sorted.(:memory)), 1_000_000)
    }
  end

snapshot = Valimc.Data.Metrics.snapshot()
delta = Map.new(counters, &{&1, Map.get(snapshot, &1, 0) - Map.get(before, &1, 0)})

summary = %{
  # Short of `seconds * speed` by the time the player stood in missing chunks.
  flown_blocks: round(:math.sqrt((x - start.x) ** 2 + (z - start.z) ** 2)),
  crossings: length(missing),
  missed: missed,
  missing_median_ms: div(pick.(missing, 0.5), 1000),
  missing_p90_ms: div(pick.(missing, 0.9), 1000),
  missing_max_ms: div(List.last(missing), 1000),
  missed_median_ms:
    div(
      pick.(Enum.filter(missing, &(&1 > 0)) |> then(&if(&1 == [], do: [0], else: &1)), 0.5),
      1000
    ),
  pool_busy_while_wanted: Float.round(pool_busy, 3),
  scheduler_busy: Float.round(scheduler_busy, 3),
  dirty_utilization: Float.round(mean.(dirty), 3),
  normal_utilization: Float.round(mean.(normal), 3),
  generated_chunks_per_second:
    Float.round(delta.worldgen_chunks / ((flown - started) / 1.0e6), 1),
  # The chunk the player stood in when the flight ended: after it stops, how
  # long it was missing (VMC-077w: no longer than while flying).
  last_missing_ms: div(List.last(crossings).missing_us, 1000),
  largest_group: largest_group
}

IO.puts(
  "#{summary.flown_blocks} blocks flown, #{summary.crossings} chunks entered, #{missed} " <>
    "missing on entry; missing time median " <>
    "#{summary.missing_median_ms} ms, p90 #{summary.missing_p90_ms} ms, max " <>
    "#{summary.missing_max_ms} ms (median of the missed #{summary.missed_median_ms} ms); " <>
    "pool #{round(pool_busy * 100)}% busy while chunks were wanted, scheduler process " <>
    "#{round(scheduler_busy * 100)}% busy, dirty schedulers " <>
    "#{round(summary.dirty_utilization * 100)}%, #{summary.generated_chunks_per_second} chunks/s " <>
    inspect(delta) <>
    "; last chunk missing #{summary.last_missing_ms} ms; largest group " <>
    inspect(largest_group)
)

record = %{
  recorded_at: DateTime.utc_now() |> DateTime.to_iso8601(),
  seed: seed,
  view_distance: distance,
  blocks_per_second: speed,
  heading_degrees: heading * 180 / :math.pi(),
  seconds: seconds,
  end: [x, z],
  pool_size: Pool.size(),
  schedulers: System.schedulers_online(),
  dirty_cpu_schedulers: :erlang.system_info(:dirty_cpu_schedulers_online),
  revision: System.cmd("git", ["rev-parse", "HEAD"]) |> elem(0) |> String.trim(),
  scope:
    "One loopback TCP spectator client flying straight at constant speed over terrain nothing generated, acknowledging at 64 chunks per tick. Other host load is not controlled; see load_average.",
  load_average: System.cmd("sysctl", ["-n", "vm.loadavg"]) |> elem(0) |> String.trim(),
  summary: summary,
  counters: delta,
  crossings: crossings,
  wants: Enum.map(wants, fn {t, w, r, m} -> [div(t - started, 1000), w, r, m] end),
  waits:
    Enum.map(waits, fn row ->
      row
      |> Map.put(:t, row.at - div(started, 1000))
      |> Map.delete(:at)
      |> Map.update!(:jobs, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
    end),
  utilization: Enum.map(util, fn {t, n, d} -> [div(t - started, 1000), n, d] end),
  groups:
    Enum.map(groups, fn {t, entries, busy, tags} ->
      [div(t - started, 1000), Float.round(busy, 3), Enum.map(entries, &Tuple.to_list/1), tags]
    end)
}

File.mkdir_p!(Path.dirname(output))
File.write!(output, JSON.encode!(record))
