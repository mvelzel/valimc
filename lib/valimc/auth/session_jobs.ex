defmodule Valimc.Auth.SessionJobs do
  use GenServer

  @moduledoc "Bounded cold-path session verification; monitored owners fence independent HTTPS jobs."

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def start(owner, token, name, digest) do
    deadline = System.monotonic_time(:millisecond) + Valimc.config(:authentication_timeout_ms)

    case GenServer.call(
           __MODULE__,
           {:start, owner, token, name, digest, deadline},
           Valimc.config(:admission_call_ms)
         ) do
      {:ok, job} -> {:ok, Map.put(job, :monitor, Process.monitor(job.pid))}
      error -> error
    end
  catch
    :exit, _ -> {:error, :authentication_busy}
  end

  def activate(job), do: send(job.pid, {:verify, job.token})

  def cancel(job) do
    Process.exit(job.pid, :kill)
    GenServer.cast(__MODULE__, {:cancel, job.pid, job.token})
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{jobs: %{}, limit: Valimc.config(:authentication_workers)}}
  end

  @impl true
  def handle_call({:start, owner, token, name, digest, deadline}, {owner, _}, state) do
    service = Valimc.config(:session_service)

    if map_size(state.jobs) >= state.limit or not Process.alive?(owner) or
         System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, :authentication_busy}, state}
    else
      {pid, ref} =
        :erlang.spawn_opt(
          fn ->
            timeout = max(deadline - System.monotonic_time(:millisecond), 0)

            receive do
              {:verify, ^token} ->
                result = service.lookup(name, digest, deadline)
                send(owner, {:session_verified, self(), token, result})
            after
              timeout -> :ok
            end
          end,
          [:link, :monitor]
        )

      owner_ref = Process.monitor(owner)
      record = %{ref: ref, owner_ref: owner_ref, token: token}
      job = %{pid: pid, token: token, deadline: deadline}
      {:reply, {:ok, job}, %{state | jobs: Map.put(state.jobs, pid, record)}}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, :authentication_busy}, state}
  @impl true
  def handle_cast({:cancel, pid, token}, state) do
    case state.jobs[pid] do
      %{token: ^token} -> {:noreply, remove(state, pid)}
      _ -> {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state) do
    case Enum.find(state.jobs, fn {_, j} -> ref in [j.ref, j.owner_ref] end) do
      {pid, _} -> {:noreply, remove(state, pid)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    for {pid, _} <- state.jobs, do: Process.exit(pid, :kill)
  end

  defp remove(state, pid) do
    job = state.jobs[pid]
    Process.demonitor(job.ref, [:flush])
    Process.demonitor(job.owner_ref, [:flush])
    Process.exit(pid, :kill)
    %{state | jobs: Map.delete(state.jobs, pid)}
  end
end
