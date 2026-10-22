defmodule Valimc.Data.Metrics do
  @moduledoc """
  Lock-free counters and BEAM resource snapshots for measurement.

  Each key gets its own `:counters` cell (write-concurrent); the ETS table only
  maps keys to cells and is written once per key. Incrementing a shared ETS
  counter from every connection serializes on one row lock under load.
  """
  @doc "Create the table; the application owns it (`Valimc.Application`)."
  def init! do
    :ets.new(__MODULE__, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  def add(key, value \\ 1), do: :counters.add(cell(key), 1, value)

  @doc "A counter's or gauge's value."
  def get(key), do: :counters.get(cell(key), 1)

  @doc "Set a gauge (a value one owner keeps current)."
  def put(key, value), do: :counters.put(cell(key), 1, value)

  defp cell(key) do
    case :ets.lookup(__MODULE__, key) do
      [{_, cell}] ->
        cell

      [] ->
        cell = :counters.new(1, [:write_concurrency])
        if :ets.insert_new(__MODULE__, {key, cell}), do: cell, else: cell(key)
    end
  end

  def snapshot do
    Map.new(:ets.tab2list(__MODULE__), fn {key, cell} -> {key, :counters.get(cell, 1)} end)
    |> Map.merge(%{
      processes: :erlang.system_info(:process_count),
      schedulers: :erlang.system_info(:schedulers_online),
      memory_bytes: :erlang.memory(:total),
      connections: DynamicSupervisor.count_children(Valimc.ConnectionSupervisor).active,
      regions: DynamicSupervisor.count_children(Valimc.RegionSupervisor).active
    })
  end
end
