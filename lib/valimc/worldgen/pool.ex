defmodule Valimc.Worldgen.Pool do
  @moduledoc """
  The one pool of generation jobs (VMC-077b): terrain, decoration and full
  chunks, and the commands that run the generator (`/locate`, `/place`). Its
  jobs make long dirty CPU NIF calls (tens of milliseconds to seconds), so it
  runs two jobs fewer than the VM has dirty CPU schedulers (at least one): an
  owner's own dirty calls never queue behind a full set of generation jobs.

  Bulk jobs (terrain) leave the last slot to jobs that finish work already
  started (decoration holding its locks, full chunks, commands a player waits
  for), so those never wait for a stream of terrain.
  """

  @doc "Jobs the pool runs at once: dirty CPU schedulers minus two, at least one."
  def size, do: max(:erlang.system_info(:dirty_cpu_schedulers_online) - 2, 1)

  def child_spec(_opts),
    do: Task.Supervisor.child_spec(name: __MODULE__, max_children: size())

  @doc "Start `fun` as a job; `{:error, :busy}` while every slot is taken."
  def start(fun) do
    case Task.Supervisor.start_child(__MODULE__, fun) do
      {:ok, pid} -> {:ok, pid}
      {:error, :max_children} -> {:error, :busy}
    end
  end

  @doc "Start bulk work: as `start/1`, but busy while at most one slot is free."
  def start_bulk(fun) do
    size = size()

    if size > 1 and DynamicSupervisor.count_children(__MODULE__).active >= size - 1,
      do: {:error, :busy},
      else: start(fun)
  end
end
