defmodule Valimc.Workers do
  @moduledoc """
  Bounded task pools. Hot-path pools are partitioned by caller, so starting a
  job never queues behind one global supervisor process.
  """

  @doc "The placement and mining job pool partition for the calling process."
  def actions, do: {:via, PartitionSupervisor, {Valimc.ActionWorkers, self()}}

  def partitions, do: max(System.schedulers_online(), 1)

  @doc "Child spec for a partitioned Task.Supervisor sharing `limit` children."
  def partitioned(name, limit) do
    per = max(div(limit + partitions() - 1, partitions()), 1)

    {PartitionSupervisor,
     child_spec: {Task.Supervisor, max_children: per}, name: name, partitions: partitions()}
  end

  @doc "Active children across all partitions of a partitioned pool."
  def active(name) do
    name
    |> PartitionSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} -> DynamicSupervisor.count_children(pid).active end)
    |> Enum.sum()
  end
end
