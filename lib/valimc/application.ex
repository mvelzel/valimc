defmodule Valimc.Application do
  @moduledoc """
  The supervision tree (VMC-077a): five domain supervisors under a
  `rest_for_one` root, each with its own restart intensity, so a crash loop in
  one domain stops at that domain's supervisor and only a domain's restart
  restarts the domains after it.

  1. Infrastructure: the world settings, tick rate, clock, stopwatch and admin
     owners and the worker pools; independent of each other (`one_for_one`).
  2. Storage: the write-ahead log's stripes (`Valimc.Storage.Log`) and the
     per-session player stores.
  3. World: the region registries, the directory, the generation schedulers
     and the region owners; a directory restart restarts the schedulers and
     owners after it.
  4. Players: admission and its tables, login workers and connections.
  5. Network: the listener, the console and RCON (`one_for_one`; a listener
     restart touches no connection).

  The world's generation (`Valimc.World.Spec`) is read before any process
  starts; a world that does not read stops the start. Tables nobody owns as
  state (metrics counters, the generation pool's slots and waiters, the
  autosave flag) are created here, owned by the application for its whole
  life, instead of by a process that only holds them.
  """
  use Application

  @impl true
  def start(_type, _args) do
    raise_open_files_limit()
    Valimc.Protocol.Data.load!()
    Valimc.World.Chunk.load!()
    Valimc.Data.BlockFacts.install!()
    Valimc.World.Spawning.install!()
    Valimc.AI.NativeFacts.install!()
    # Generation threads first: a new world's spawn search generates.
    Valimc.Worldgen.Pool.init!()
    Valimc.Worldgen.Generator.init!()
    Valimc.Net.LoginKeys.init!()
    Valimc.Commands.init!()
    Valimc.Data.Metrics.init!()
    Valimc.Data.ProfileTicks.init!()
    Valimc.Entity.Ids.init!()
    Valimc.World.Saving.init!()
    Valimc.World.GameTick.init!()
    Valimc.Storage.Log.init!()

    if not Valimc.Player.GameMode.valid?(Valimc.config(:default_game_mode)),
      do: raise("Invalid default game mode")

    schedulers = max(System.schedulers_online(), 1)
    # Chunk packet encodes start without a call (VMC-077w).
    Valimc.World.Jobs.init_slots!(:chunk_encode, schedulers)
    # Mobs' path searches, a batch per section (VMC-041b).
    Valimc.World.Jobs.init_slots!(:paths, schedulers)

    infrastructure = [
      Valimc.World.Settings,
      Valimc.World.TickRate,
      {Valimc.World.Clock, []},
      {Valimc.World.Stopwatches, []},
      {Valimc.Admin.Lists, []},
      Valimc.Admin.Profiler,
      {Task.Supervisor, name: Valimc.ItemWorkers, max_children: schedulers},
      {Task.Supervisor, name: Valimc.TransferWorkers, max_children: schedulers * 4}
    ]

    storage = [
      # The write-ahead log's stripes, per world folder (VMC-077f).
      {Registry, keys: :unique, name: Valimc.StorageRegistry},
      dynamic(Valimc.StorageSupervisor, 1024),
      # The processes holding a player's durable state (`Valimc.Player.Storage`).
      {Registry, keys: :duplicate, name: Valimc.PlayerRegistry}
    ]

    # A directory restart fences every region owner and its writer (VMC-019b3a).
    world =
      [
        {Registry, keys: :unique, name: Valimc.RegionRegistry},
        # Region topic => subscribed connections (duplicate keys).
        {Registry, keys: :duplicate, name: Valimc.VisibilityRegistry},
        {Valimc.World.Directory, []},
        # One generation scheduler per generated dimension (VMC-077n), stopped
        # after the regions that persist its chunks.
        {Registry, keys: :unique, name: Valimc.Worldgen.Schedulers},
        dynamic(Valimc.Worldgen.SchedulerSupervisor, Valimc.config(:max_regions)),
        dynamic(Valimc.RegionSupervisor, Valimc.config(:max_regions)),
        # One regionizer per dimension decides which sections share a group
        # (VMC-077j2); one that restarts rebuilds from the routes.
        {Registry, keys: :unique, name: Valimc.Regionizers}
        | Enum.map(Valimc.World.Dimension.ids(), &{Valimc.World.Regionizer, &1})
      ] ++ [{Valimc.World.ForcedChunks, []}]

    players = [
      Valimc.Player.PlayerList,
      {Valimc.Net.LoginJobs, :key},
      {Valimc.Net.Auth.DiscoverySupervisor, []},
      {Valimc.Net.LoginJobs, :session},
      # Players' command jobs: at most one per connection (VMC-077a).
      {Task.Supervisor,
       name: Valimc.CommandWorkers, max_children: Valimc.config(:max_connections)},
      dynamic(Valimc.ConnectionSupervisor, Valimc.config(:max_connections))
    ]

    # VMC-010f: the console reads standard input once the server listens.
    # VMC-010g: RCON, when enabled.
    network =
      [Valimc.Net.Listener, Valimc.Net.ProfileWeb] ++
        if(Valimc.config(:console), do: [Valimc.Net.Console], else: []) ++
        if(Valimc.config(:rcon), do: [Valimc.Net.Rcon], else: [])

    Supervisor.start_link(
      [
        domain(Valimc.Infrastructure, infrastructure, :one_for_one),
        domain(Valimc.Storage, storage, :rest_for_one),
        domain(Valimc.WorldSupervisor, world, :rest_for_one),
        domain(Valimc.PlayersSupervisor, players, :rest_for_one),
        domain(Valimc.Network, network, :one_for_one)
      ],
      strategy: :rest_for_one,
      max_restarts: 3,
      max_seconds: 30,
      name: Valimc.Supervisor
    )
  end

  # A domain absorbs bursts of its children's crashes (10 in 10 s) before it
  # gives up and the root restarts it and the domains after it.
  defp domain(name, children, strategy) do
    %{
      id: name,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [children, [strategy: strategy, max_restarts: 10, max_seconds: 10, name: name]]}
    }
  end

  # Vanilla's JVM raises the soft open-files limit toward the hard one; sockets
  # need it (the logs open O(stripes) files, VMC-077f).
  defp raise_open_files_limit do
    require Logger

    case Valimc.Native.set_open_files_limit(1_048_576) do
      {:ok, {soft, hard}} -> Logger.info("Open files: limit #{soft} (hard #{hard})")
      {:error, reason} -> Logger.warning("Open files limit unchanged: #{inspect(reason)}")
    end
  end

  defp dynamic(name, max_children),
    do: {DynamicSupervisor, strategy: :one_for_one, name: name, max_children: max_children}
end
