defmodule Valimc.Worldgen.Pool do
  @moduledoc """
  The one pool of generation jobs (VMC-077b): terrain, decoration and full
  chunks, and the commands that run the generator (`/locate`, `/place`). Its
  jobs make long dirty CPU NIF calls (tens of milliseconds to seconds), so it
  runs two jobs fewer than the VM has dirty CPU schedulers (at least one): an
  owner's own dirty calls never queue behind a full set of generation jobs.

  Bulk jobs (terrain) leave the last slot to jobs that finish work already
  started (decoration, full chunks, commands a player waits for), so those
  never wait for a stream of terrain.

  A caller that finds no slot asks to be told (`notify/0`): the next job to
  end sends it `{Valimc.Worldgen.Pool, :free}` (VMC-077n), so nothing polls.
  A job is a plain process its caller monitors, counted in an atomic slot
  counter: starting one is no call to another process, and the counter
  bounds them.
  """

  @slots {__MODULE__, :slots}
  @waiters Valimc.Worldgen.Pool.Waiters

  @doc "Jobs the pool runs at once: dirty CPU schedulers minus two, at least one."
  def size, do: max(:erlang.system_info(:dirty_cpu_schedulers_online) - 2, 1)

  @doc "Create the slot counter and the waiter table; the application owns them."
  def init! do
    :ets.new(@waiters, [:named_table, :public, :duplicate_bag])
    :persistent_term.put(@slots, :atomics.new(1, signed: true))
    :ok
  end

  @doc "Start `fun` as a job; `{:error, :busy}` while every slot is taken."
  def start(fun), do: with({:ok, pid, _} <- start_within(size(), fun), do: {:ok, pid})

  @doc "Start bulk work: as `start/1`, but busy while at most one slot is free."
  def start_bulk(fun) do
    limit = if size() > 1, do: size() - 1, else: 1
    with {:ok, pid, _} <- start_within(limit, fun), do: {:ok, pid}
  end

  @doc "Slots free now (for bulk work, one fewer)."
  def free(bulk \\ false) do
    limit = if bulk and size() > 1, do: size() - 1, else: size()
    max(limit - :atomics.get(:persistent_term.get(@slots), 1), 0)
  end

  @doc """
  Send the caller `{Valimc.Worldgen.Pool, :free}` when the next job ends (once).
  Ask before trying again, so a job that ends in between still wakes it.
  """
  def notify, do: :ets.insert(@waiters, {:waiting, self()})

  defp start_within(limit, fun) do
    slots = :persistent_term.get(@slots)

    if :atomics.add_get(slots, 1, 1) <= limit do
      slot = {slots, :atomics.new(1, [])}

      pid =
        spawn(fn ->
          try do
            fun.()
          after
            release(slot)
          end
        end)

      {:ok, pid, slot}
    else
      :atomics.sub(slots, 1, 1)
      {:error, :busy}
    end
  end

  # Once per job (its end, or the caller that killed it).
  defp release({slots, once}) do
    if :atomics.compare_exchange(once, 1, 0, 1) == :ok do
      :atomics.sub(slots, 1, 1)
      for {_, pid} <- :ets.take(@waiters, :waiting), do: send(pid, {__MODULE__, :free})
    end

    :ok
  end

  @doc """
  Run `fun` as a job and wait for its value (`/locate`, `/place`, VMC-077a):
  `{:ok, value}`, or `{:error, reason}` when no slot frees up, the job fails or
  `timeout` milliseconds pass (the job is then stopped).
  """
  def run(fun, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    {caller, ref} = {self(), make_ref()}

    with {:ok, pid, slot} <- start_by(fn -> send(caller, {ref, fun.()}) end, deadline) do
      monitor = Process.monitor(pid)

      receive do
        {^ref, value} ->
          Process.demonitor(monitor, [:flush])
          {:ok, value}

        {:DOWN, ^monitor, :process, ^pid, reason} ->
          {:error, reason}
      after
        max(deadline - System.monotonic_time(:millisecond), 0) ->
          Process.exit(pid, :kill)
          Process.demonitor(monitor, [:flush])
          release(slot)
          {:error, :timeout}
      end
    end
  end

  defp start_by(fun, deadline) do
    case start_within(size(), fun) do
      {:error, :busy} ->
        notify()

        case start_within(size(), fun) do
          {:error, :busy} ->
            receive do
              {__MODULE__, :free} -> start_by(fun, deadline)
            after
              max(deadline - System.monotonic_time(:millisecond), 0) -> {:error, :busy}
            end

          started ->
            started
        end

      started ->
        started
    end
  end
end
