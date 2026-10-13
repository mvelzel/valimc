defmodule Valimc.Metrics do
  use GenServer
  @moduledoc "Lock-free counters and BEAM resource snapshots for measurement."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  @impl true
  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    {:ok, nil}
  end

  def add(key, value \\ 1), do: :ets.update_counter(__MODULE__, key, {2, value}, {key, 0})

  def snapshot do
    Map.new(:ets.tab2list(__MODULE__))
    |> Map.merge(%{
      players: Valimc.Players.count(),
      processes: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online),
      memory_bytes: :erlang.memory(:total),
      connections: DynamicSupervisor.count_children(Valimc.ConnectionSupervisor).active,
      regions: DynamicSupervisor.count_children(Valimc.RegionSupervisor).active
    })
  end
end
