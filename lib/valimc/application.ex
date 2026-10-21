defmodule Valimc.Application do
  use Application
  @impl true
  def start(_type, _args) do
    if not Valimc.GameMode.valid?(Valimc.config(:default_game_mode)),
      do: raise("Invalid default game mode")

    # VMC-074: the open-files limit and the logs' share of it, before any log opens.
    Valimc.FileBudget.init!()
    Valimc.Protocol.Data.load!()
    Valimc.World.Chunk.load!()
    Valimc.World.Blocks.init!()
    Valimc.World.Light.init!()
    Valimc.World.Generator.init!()
    Valimc.World.Spawn.load!()
    Valimc.LoginKeys.init!()

    children = [
      {Task.Supervisor,
       name: Valimc.ItemSimulationWorkers, max_children: max(System.schedulers_online() * 4, 1)},
      {Task.Supervisor,
       name: Valimc.ItemGeometryWorkers, max_children: max(System.schedulers_online() * 8, 1)},
      Valimc.Metrics,
      Valimc.World.TickRate,
      Valimc.World.Saving,
      {Valimc.World.Clock, []},
      {Valimc.World.Stopwatches, []},
      {Registry, keys: :unique, name: Valimc.RegionRegistry},
      {Registry, keys: :duplicate, name: Valimc.VisibilityRegistry},
      {Valimc.Admin.Lists, []},
      Valimc.Players,
      Valimc.PlayerLog,
      {Registry, keys: :unique, name: Valimc.PlayerStoreRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Valimc.PlayerStoreSupervisor,
       max_children: Valimc.config(:max_connections)},
      {Task.Supervisor,
       name: Valimc.ChunkWorkers, max_children: max(System.schedulers_online(), 1)},
      {Task.Supervisor,
       name: Valimc.ItemWorkers, max_children: max(System.schedulers_online(), 1)},
      {Valimc.World.Directory, []},
      {Registry, keys: :unique, name: Valimc.RegionStoreRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Valimc.RegionStoreSupervisor,
       max_children: Valimc.config(:max_regions)},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Valimc.RegionSupervisor,
       max_children: Valimc.config(:max_regions)},
      {Valimc.World.ForcedChunks, []},
      {Task.Supervisor,
       name: Valimc.TransferWorkers, max_children: max(System.schedulers_online() * 4, 1)},
      # Generation (VMC-025d): proto owners, their terrain jobs, and their
      # decoration and full-chunk jobs in a pool of their own (so a region
      # whose terrain is ready never waits behind other terrain), all on
      # dirty schedulers.
      {Task.Supervisor,
       name: Valimc.WorldgenWorkers,
       max_children: max(:erlang.system_info(:dirty_cpu_schedulers_online), 1)},
      {Task.Supervisor,
       name: Valimc.DecorationWorkers,
       max_children: max(:erlang.system_info(:dirty_cpu_schedulers_online), 1)},
      Valimc.Worldgen.TerrainBoard,
      {Registry, keys: :unique, name: Valimc.ProtoRegistry},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Valimc.ProtoSupervisor,
       max_children: Valimc.config(:max_regions) * 2},
      Valimc.Workers.partitioned(
        Valimc.CollisionWorkers,
        Valimc.Physics.CollisionQuery.worker_limit()
      ),
      {Valimc.KeyExchange, []},
      {Valimc.Auth.DiscoverySupervisor, []},
      {Valimc.Auth.SessionJobs, []},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Valimc.ConnectionSupervisor,
       max_children: Valimc.config(:max_connections)},
      Valimc.Listener
    ]

    # VMC-010f: the console reads standard input once the server listens.
    children = children ++ if(Valimc.config(:console), do: [Valimc.Console], else: [])

    # Restart dependent owners after infrastructure loss; listener failures stay local.
    Supervisor.start_link(children, strategy: :rest_for_one, name: Valimc.Supervisor)
  end
end
