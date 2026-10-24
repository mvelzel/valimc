# VMC-078: a short complete owner tick with natural spawning and real
# loopback survival sessions. This is a tick-budget gate, not a capacity or
# cross-server comparison. Terrain is the same synthetic plains surface and
# three cave layers in both runs; only player count/positions change.
# MIX_ENV=bench mix run --no-start bench/survival_group.exs BASE OUTPUT 1|8 [TICKS]
Code.require_file("test/support/client.ex")

defmodule Bench.SurvivalGroup do
  alias Valimc.Data.{Blocks, Grid}
  alias Valimc.Player.{PlayerList, Storage}
  alias Valimc.Protocol.{Data, Wire}
  alias Valimc.TestClient, as: Client
  alias Valimc.World.{Region, RegionStorage}

  def terrain(base) do
    caves = Enum.concat([-40..-37, -10..-7, 20..23])

    layers =
      for y <- -64..319, into: <<>> do
        name =
          cond do
            y == -64 -> "bedrock"
            y in caves -> "air"
            y < 60 -> "stone"
            y < 63 -> "dirt"
            y == 63 -> "grass_block"
            true -> "air"
          end

        <<Blocks.default_state(name)::16>>
      end

    biome = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
    {:ok, image} = Valimc.Native.column_layers_image(layers, biome)

    for x <- -2..2, z <- -2..2 do
      key = {x, z}
      images = Map.new(Valimc.World.RegionGeneration.chunks_of(key), &{&1, image})
      :ok = RegionStorage.import(base, :overworld, key, %{columns: images})
    end
  end

  def positions(1), do: [{0, 0}]
  def positions(8), do: for(x <- [-96, 0, 96], z <- [-96, 0, 96], {x, z} != {0, 0}, do: {x, z})

  # Glass keeps stationary survival clients safe; entities beyond the native
  # 24-block exclusion radius still spawn, path, travel and interact normally.
  def shelter({x, z}) do
    glass = Blocks.default_state("glass")

    writes =
      for dx <- -2..2,
          dz <- -2..2,
          y <- 64..67,
          abs(dx) == 2 or abs(dz) == 2 or y == 67,
          into: %{},
          do: {{x + dx, y, z + dz}, glass}

    for {key, cells} <-
          Enum.group_by(writes, fn {{x, _, z}, _} -> Grid.region_key(Grid.chunk_key(x, z)) end) do
      {:ok, owner} = Valimc.World.owner({:overworld, elem(key, 0), elem(key, 1)})
      {:ok, observed} = Region.observe_blocks(owner, Enum.map(cells, &elem(&1, 0)))
      {:ok, _} = Region.set_blocks(owner, observed.fence, Map.new(cells))
    end
  end

  def client(parent, index, {x, z}) do
    name = "Budget#{index}"
    {uuid, client} = Client.configure(name)
    settings = [Wire.string("en_us"), <<10::signed-8, 0, 1, 0x7F, 1, 0, 1, 0>>]
    client = Client.send_packet(client, :configuration, "client_information", settings)
    client = Client.send_packet(client, :configuration, "finish_configuration", <<>>)
    {_, client} = Client.await(client, :play, "login")
    {at, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", at)
    client = Client.load_world(client)
    client = Client.send_packet(client, :play, "player_loaded", <<>>)

    connection =
      Valimc.TestWait.until(fn ->
        Enum.find_value(PlayerList.all(), &(&1.name == name && &1.pid))
      end)

    Valimc.TestWait.until(fn -> not Valimc.TestConn.state(connection).teleport_pending end)

    :ok =
      Valimc.TestConn.teleport(connection, %{
        x: x + 0.5,
        y: 64.0,
        z: z + 0.5,
        yaw: 0.0,
        pitch: 0.0
      })

    {at, client} = Client.await(client, :play, "player_position")
    client = Client.auto_reply(client, :play, "player_position", at)
    Valimc.TestWait.until(fn -> not Valimc.TestConn.state(connection).teleport_pending end)
    send(parent, {:ready, index, uuid, connection, client.socket})
    read(parent, index, client)
  end

  defp read(parent, index, client) do
    {id, payload, client} = Client.read(client)
    name = Data.name(:play, :clientbound, id)
    if name == "disconnect", do: send(parent, {:disconnected, index, Base.encode64(payload)})
    read(parent, index, Client.auto_reply(client, :play, name, payload))
  rescue
    error in MatchError ->
      if error.term == {:error, :closed} do
        receive do
          :stop -> :ok
        after
          0 -> send(parent, {:disconnected, index, "socket closed"})
        end
      else
        reraise error, __STACKTRACE__
      end
  end

  def group(clients) do
    Valimc.TestWait.until(
      fn ->
        owners = clients |> Enum.map(&Storage.host(&1.uuid)) |> Enum.uniq()

        case owners do
          [pid] when is_pid(pid) ->
            state = :sys.get_state(pid)

            if map_size(state.players) == length(clients) and
                 Enum.all?(state.players, fn {_, p} ->
                   p.session.life_stage == :alive and
                     p.session.player.game_mode.current == :survival
                 end),
               do:
                 {pid,
                  state.sections
                  |> Map.values()
                  |> hd()
                  |> Map.fetch!(:resource)
                  |> Map.fetch!(:epoch)}

          _ ->
            nil
        end
      end,
      60_000
    )
  end

  def step(owner, ticks) do
    initial = System.monotonic_time(:millisecond)

    for n <- 1..ticks do
      receive do
        {:disconnected, index, reason} -> raise("client #{index} disconnected: #{reason}")
      after
        0 -> :ok
      end

      {us, {:ok, _}} = :timer.tc(fn -> Region.step(owner, 1) end)
      wait = initial + n * 50 - System.monotonic_time(:millisecond)
      if wait > 0, do: Process.sleep(wait)
      us
    end
  end

  def population({pid, _}) do
    state = :sys.get_state(pid)

    mobs =
      for {_, section} <- state.sections,
          {_, %{kind: :mob, body: body}} <- section.resource.entities.store.entries,
          do: body.type

    %{
      sections: map_size(state.sections),
      mobs: length(mobs),
      types: Enum.frequencies(mobs),
      players: map_size(state.players),
      queue: elem(Process.info(pid, :message_queue_len), 1)
    }
  end

  def profile(owner, :start) do
    modules = [
      Valimc.World.Region,
      Valimc.World.RegionData,
      Valimc.World.BlockRules,
      Valimc.World.Blocks,
      Valimc.Entity.Store,
      Valimc.Entity.Body,
      Valimc.Entity.MobTicks,
      Valimc.AI,
      Valimc.AI.World,
      Valimc.Native,
      Valimc.Player.Host,
      Valimc.World.Spawning
    ]

    for module <- modules, do: :erlang.trace_pattern({module, :_, :_}, true, [:call_time])
    :erlang.trace(elem(owner, 0), true, [:call])
    modules
  end

  def profile(owner, modules) do
    :erlang.trace(elem(owner, 0), false, [:call])

    rows =
      for module <- modules,
          {name, arity} <- module.module_info(:functions),
          {:call_time, entries} <- [:erlang.trace_info({module, name, arity}, :call_time)],
          is_list(entries),
          {pid, calls, seconds, us} <- entries,
          pid == elem(owner, 0),
          do: %{
            function: "#{inspect(module)}.#{name}/#{arity}",
            calls: calls,
            us: seconds * 1_000_000 + us
          }

    for module <- modules, do: :erlang.trace_pattern({module, :_, :_}, false, [:call_time])
    Enum.sort_by(rows, &(-&1.us))
  end

  def owner_info({pid, _}) do
    Process.info(pid, [
      :memory,
      :total_heap_size,
      :reductions,
      :garbage_collection,
      :message_queue_len
    ])
    |> Map.new()
    |> Map.update!(:garbage_collection, &Map.new/1)
  end

  def stats(samples) do
    sorted = Enum.sort(samples)
    n = length(sorted)
    at = fn q -> Enum.at(sorted, min(n - 1, floor(n * q))) / 1000 end

    %{
      p50_ms: at.(0.5),
      p95_ms: at.(0.95),
      p99_ms: at.(0.99),
      max_ms: List.last(sorted) / 1000,
      over_budget: Enum.count(samples, &(&1 > 50_000)),
      ticks: n
    }
  end
end

[base, output, count | rest] = System.argv()
base = Path.expand(base)
count = String.to_integer(count)
true = count in [1, 8]
ticks = String.to_integer(List.first(rest) || "200")
true = ticks in 20..1200
false = File.exists?(base)
File.mkdir_p!(base)

for {key, value} <- [
      world_path: base,
      port: 0,
      generator: :flat,
      seed: 42,
      default_game_mode: :survival,
      view_distance: 10,
      simulation_distance: 8,
      region_ticks: :manual,
      natural_spawning: true,
      console: false
    ],
    do: Application.put_env(:valimc, key, value)

{:ok, _} = Application.ensure_all_started(:valimc)
Bench.SurvivalGroup.terrain(base)
:ok = Valimc.World.Clock.configure({"minecraft:overworld", :paused, true})
:ok = Valimc.World.Clock.configure({"minecraft:overworld", :ticks, 18_000})
:ok = Valimc.World.Clock.flush()
parent = self()

clients =
  for {position, index} <- Enum.with_index(Bench.SurvivalGroup.positions(count), 1) do
    Bench.SurvivalGroup.shelter(position)

    {worker, monitor} =
      spawn_monitor(fn -> Bench.SurvivalGroup.client(parent, index, position) end)

    receive do
      {:ready, ^index, uuid, connection, socket} ->
        %{uuid: uuid, connection: connection, socket: socket, worker: worker, monitor: monitor}

      {:DOWN, ^monitor, _, _, reason} ->
        raise("client setup failed: #{inspect(reason)}")
    after
      60_000 -> raise("client setup timed out")
    end
  end

owner = Bench.SurvivalGroup.group(clients)
_ = Bench.SurvivalGroup.step(owner, 200)
before = Bench.SurvivalGroup.population(owner)
true = before.mobs > 0
profile = if System.get_env("PROFILE") == "calls", do: Bench.SurvivalGroup.profile(owner, :start)
owner_before = Bench.SurvivalGroup.owner_info(owner)
metrics_before = Valimc.Data.Metrics.snapshot()
start = System.monotonic_time(:millisecond)
samples = Bench.SurvivalGroup.step(owner, ticks)
elapsed = System.monotonic_time(:millisecond) - start
after_run = Bench.SurvivalGroup.population(owner)
owner_after = Bench.SurvivalGroup.owner_info(owner)

metrics =
  for {key, value} <- Valimc.Data.Metrics.snapshot(),
      delta = value - Map.get(metrics_before, key, 0),
      delta != 0,
      into: %{},
      do: {key, delta}

profile = if profile, do: Bench.SurvivalGroup.profile(owner, profile)

true = after_run.players == count
stats = Bench.SurvivalGroup.stats(samples)
{revision, 0} = System.cmd("git", ["rev-parse", "HEAD"])
{load, 0} = System.cmd("uptime", [])

result = %{
  revision: String.trim(revision),
  mix_env: Mix.env(),
  elixir: System.version(),
  otp: :erlang.system_info(:otp_release) |> List.to_string(),
  schedulers: :erlang.system_info(:schedulers_online),
  load: String.trim(load),
  players: count,
  before: before,
  after: after_run,
  elapsed_ms: elapsed,
  stats: stats,
  raw_tick_us: samples,
  harness_sha256: :crypto.hash(:sha256, File.read!(__ENV__.file)) |> Base.encode16(case: :lower),
  owner_before: owner_before,
  owner_after: owner_after,
  metrics: metrics,
  profile: profile,
  fixture:
    "seed42 plains surface, three cave layers; real stationary survival sessions in glass shelters; natural spawning, AI, physics, block rules and group durability active"
}

File.mkdir_p!(Path.dirname(output))
File.write!(output, JSON.encode!(result))
IO.inspect(Map.drop(result, [:raw_tick_us]), label: "survival group gate", limit: :infinity)

for c <- clients do
  send(c.worker, :stop)
  :gen_tcp.close(c.socket)
end

:ok = Valimc.World.Region.flush(elem(owner, 0))
Application.stop(:valimc)
if stats.p99_ms > 50.0 or after_run.mobs == 0, do: System.halt(1)
