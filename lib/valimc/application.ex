defmodule Valimc.Application do
  use Application
  @impl true
  def start(_type, _args) do
    Valimc.Protocol.Data.load!()
    Valimc.World.Chunk.load!()

    children = [
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
      {DynamicSupervisor,
       strategy: :one_for_one,
       name: Valimc.RegionSupervisor,
       max_children: Valimc.config(:max_regions)},
      {Task.Supervisor,
       name: Valimc.TransferWorkers, max_children: max(System.schedulers_online() * 4, 1)},
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
