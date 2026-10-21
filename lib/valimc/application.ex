defmodule Valimc.Application do
  @moduledoc """
  The supervision tree (VMC-077a): five domain supervisors under a
  `rest_for_one` root, each with its own restart intensity, so a crash loop in
  one domain stops at that domain's supervisor and only a domain's restart
  restarts the domains after it.

  1. Infrastructure: the world settings, tick rate, clock, stopwatch and admin
     owners and the worker pools; independent of each other (`one_for_one`).
  2. Storage: the player logs and the per-session and per-region stores.
  3. World: region and proto registries, the directory, region and proto owners.
  4. Players: admission and its tables, login workers and connections.
  5. Network: the listener, the console and RCON (`one_for_one`; a listener
     restart touches no connection).

  The world's generation (`Valimc.World.Spec`) is read before any process
  starts; a world that does not read stops the start. Tables nobody owns as state (metrics counters, the terrain board, the
  autosave flag) are created here, owned by the application for its whole life,
  instead of by a process that only holds them.
  """
  use Application

  @impl true
  def start(_type, _args) do
    # VMC-074: the open-files limit and the logs' share of it, before any log opens.
    Valimc.FileBudget.init!()
    Valimc.Protocol.Data.load!()
    Valimc.World.Chunk.load!()
    Valimc.World.Blocks.init!()
    Valimc.World.Light.init!()
    Valimc.World.Generator.init!()
    Valimc.LoginKeys.init!()
    Valimc.Metrics.init!()
    Valimc.World.Saving.init!()
    Valimc.Worldgen.TerrainBoard.init!()

    if not Valimc.GameMode.valid?(Valimc.config(:default_game_mode)),
      do: raise("Invalid default game mode")

    schedulers = max(System.schedulers_online(), 1)

    infrastructure = [
      Valimc.World.Settings,
      Valimc.World.TickRate,
      {Valimc.World.Clock, []},
      {Valimc.World.Stopwatches, []},
      {Valimc.Admin.Lists, []},
      {Task.Supervisor, name: Valimc.ItemSimulationWorkers, max_children: schedulers * 4},
      {Task.Supervisor, name: Valimc.ItemGeometryWorkers, max_children: schedulers * 8},
      {Task.Supervisor, name: Valimc.ChunkWorkers, max_children: schedulers},
      {Task.Supervisor, name: Valimc.ItemWorkers, max_children: schedulers},
      {Task.Supervisor, name: Valimc.TransferWorkers, max_children: schedulers * 4},
      # The one pool of generation jobs, below the dirty scheduler count (VMC-077b).
      Valimc.Worldgen.Pool,
      Valimc.Workers.partitioned(
        Valimc.CollisionWorkers,
        Valimc.Physics.CollisionQuery.worker_limit()
      )
    ]

    storage = [
      Valimc.PlayerLog,
      {Registry, keys: :unique, name: Valimc.PlayerStoreRegistry},
      dynamic(Valimc.PlayerStoreSupervisor, Valimc.config(:max_connections)),
      {Registry, keys: :unique, name: Valimc.RegionStoreRegistry},
      dynamic(Valimc.RegionStoreSupervisor, Valimc.config(:max_regions))
    ]

    world = [
      {Registry, keys: :unique, name: Valimc.RegionRegistry},
      # Region topic => subscribed connections (duplicate keys).
      {Registry, keys: :duplicate, name: Valimc.VisibilityRegistry},
      {Valimc.World.Directory, []},
      dynamic(Valimc.RegionSupervisor, Valimc.config(:max_regions)),
      {Valimc.World.ForcedChunks, []},
      {Registry, keys: :unique, name: Valimc.ProtoRegistry},
      dynamic(Valimc.ProtoSupervisor, Valimc.config(:max_regions) * 2)
    ]

    players = [
      Valimc.Players,
      {Valimc.KeyExchange, []},
      {Valimc.Auth.DiscoverySupervisor, []},
      {Valimc.Auth.SessionJobs, []},
      dynamic(Valimc.ConnectionSupervisor, Valimc.config(:max_connections))
    ]

    # VMC-010f: the console reads standard input once the server listens.
    # VMC-010g: RCON, when enabled.
    network =
      [Valimc.Listener] ++
        if(Valimc.config(:console), do: [Valimc.Console], else: []) ++
        if(Valimc.config(:rcon), do: [Valimc.Rcon], else: [])

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

  defp dynamic(name, max_children),
    do: {DynamicSupervisor, strategy: :one_for_one, name: name, max_children: max_children}
end
