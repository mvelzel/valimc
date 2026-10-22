defmodule Valimc.Net.Auth.DiscoverySupervisor do
  use Supervisor
  def start_link(_), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)
  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Registry, keys: :duplicate, name: Valimc.Auth.DiscoveryWaiters},
        {Valimc.Net.Auth.Discovery, []}
      ],
      strategy: :rest_for_one
    )
  end
end
