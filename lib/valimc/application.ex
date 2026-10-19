defmodule Valimc.Application do
  use Application
  @impl true
  def start(_type, _args) do
    if not Valimc.GameMode.valid?(Valimc.config(:default_game_mode)),
      do: raise("Invalid default game mode")

    Valimc.Protocol.Data.load!()
    Valimc.World.Chunk.load!()
    Valimc.World.Blocks.init!()

    children = [
      {Task.Supervisor,
       name: Valimc.ItemSimulationWorkers, max_children: max(System.schedulers_online() * 4, 1)},
      {Task.Supervisor,
       name: Valimc.ItemGeometryWorkers, max_children: max(System.schedulers_online() * 8, 1)},
      Valimc.Metrics,
      {Valimc.World.Clock, []},
      {Registry, keys: :unique, name: Valimc.RegionRegistry},
      {Registry, keys: :duplicate, name: Valimc.VisibilityRegistry},
      Valimc.Players,
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
      {Task.Supervisor,
       name: Valimc.TransferWorkers, max_children: max(System.schedulers_online() * 4, 1)},
      Valimc.Workers.partitioned(
        Valimc.CollisionWorkers,
        Valimc.Physics.CollisionQuery.worker_limit()
      ),
      {Valimc.LoginKeys, []},
      {Valimc.KeyExchange, []},
      {Valimc.Auth.DiscoverySupervisor, []},
      {Valimc.Auth.SessionJobs, []},
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Valimc.ConnectionSupervisor,
       max_children: Valimc.config(:max_connections)},
      Valimc.Listener
    ]

    # Restart dependent owners after infrastructure loss; listener failures stay local.
    Supervisor.start_link(children, strategy: :rest_for_one, name: Valimc.Supervisor)
  end
end
