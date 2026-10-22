defmodule Valimc.Net.Auth.Discovery do
  use GenServer
  alias Valimc.Net.Auth.DiscoveryDocument

  @moduledoc "One cold refresh owner; immutable routes in ETS and bounded initial-ready subscriptions."

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def refresh, do: GenServer.cast(__MODULE__, :refresh)

  def endpoint(deadline) do
    case if(System.monotonic_time(:millisecond) < deadline, do: publication(), else: nil) do
      %{ready: true, endpoint: uri} -> route(uri)
      %{owner: owner, ready: false} -> await_initial(owner, deadline)
      _ -> {:error, :discovery_unavailable}
    end
  end

  def publication do
    case :ets.lookup(__MODULE__, :route) do
      [{:route, view}] -> view
      _ -> nil
    end
  rescue
    ArgumentError -> nil
  end

  defp route(uri) when is_binary(uri), do: {:ok, uri}
  defp route(_), do: {:error, :discovery_unavailable}

  defp await_initial(owner, deadline) do
    token = make_ref()
    ref = Process.monitor(owner)
    {:ok, _} = Registry.register(Valimc.Auth.DiscoveryWaiters, :initial, token)

    try do
      case publication() do
        %{owner: ^owner, ready: true, endpoint: uri} ->
          route(uri)

        %{owner: ^owner, ready: false} ->
          receive do
            {:discovery_ready, ^token} ->
              case publication() do
                %{owner: ^owner, ready: true, endpoint: uri} ->
                  if System.monotonic_time(:millisecond) < deadline,
                    do: route(uri),
                    else: {:error, :discovery_unavailable}

                _ ->
                  {:error, :discovery_unavailable}
              end

            {:DOWN, ^ref, :process, ^owner, _} ->
              {:error, :discovery_unavailable}
          after
            max(deadline - System.monotonic_time(:millisecond), 0) ->
              {:error, :discovery_unavailable}
          end

        _ ->
          {:error, :discovery_unavailable}
      end
    after
      Process.demonitor(ref, [:flush])
      Registry.unregister(Valimc.Auth.DiscoveryWaiters, :initial)
    end
  end

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    table = :ets.new(__MODULE__, [:named_table, :protected, :set, read_concurrency: true])
    enabled = Valimc.config(:online_mode)

    state = %{
      table: table,
      enabled: enabled,
      ready: not enabled,
      loaded: false,
      endpoint: nil,
      failures: 0,
      job: nil,
      timer: nil,
      generation: make_ref()
    }

    publish(state)
    if enabled, do: send(self(), :start)
    {:ok, state}
  end

  @impl true
  def handle_cast(:refresh, state) do
    if state.enabled and state.job == nil do
      if state.timer, do: Process.cancel_timer(state.timer)
      {:noreply, start_job(%{state | timer: nil, generation: make_ref()})}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(:start, state), do: {:noreply, start_job(state)}

  def handle_info({:refresh, generation}, %{generation: generation, job: nil} = state),
    do: {:noreply, start_job(%{state | timer: nil})}

  def handle_info({:refresh, _}, state), do: {:noreply, state}

  def handle_info(
        {:discovery_result, pid, token, result},
        %{job: %{pid: pid, token: token} = job} = state
      ) do
    result =
      if System.monotonic_time(:millisecond) < job.deadline,
        do: result,
        else: {:error, :discovery_timeout}

    {:noreply, finish(state, result)}
  end

  def handle_info({:discovery_result, _, _, _}, state), do: {:noreply, state}

  def handle_info({:discovery_deadline, token}, %{job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do: {:noreply, finish(state, {:error, :discovery_timeout})},
      else: {:noreply, state}
  end

  def handle_info({:discovery_deadline, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{job: %{ref: ref}} = state),
    do: {:noreply, finish(state, {:error, :discovery_worker_failed})}

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, state}

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  defp start_job(%{enabled: false} = state), do: state
  defp start_job(%{job: job} = state) when job != nil, do: state

  defp start_job(state) do
    owner = self()
    token = make_ref()
    deadline = System.monotonic_time(:millisecond) + 5000
    fetcher = Valimc.config(:discovery_service)

    {pid, ref} =
      :erlang.spawn_opt(
        fn ->
          result = fetcher.fetch(deadline)
          send(owner, {:discovery_result, self(), token, result})
        end,
        [:link, :monitor]
      )

    timer = Process.send_after(self(), {:discovery_deadline, token}, 5000)
    %{state | job: %{pid: pid, ref: ref, token: token, deadline: deadline, timer: timer}}
  end

  defp finish(state, result) do
    Process.cancel_timer(state.job.timer)
    Process.demonitor(state.job.ref, [:flush])
    Process.exit(state.job.pid, :kill)
    state = %{state | job: nil, ready: true}

    state =
      case result do
        {:ok, uri} ->
          if uri == nil or DiscoveryDocument.valid_endpoint?(uri),
            do: %{state | endpoint: uri, loaded: true, failures: 0},
            else: state

        _ ->
          state
      end

    publish(state)

    Registry.dispatch(Valimc.Auth.DiscoveryWaiters, :initial, fn entries ->
      for {pid, token} <- entries, do: send(pid, {:discovery_ready, token})
    end)

    delay = DiscoveryDocument.retry_delay(state.loaded, state.failures)
    generation = make_ref()
    timer = Process.send_after(self(), {:refresh, generation}, delay)

    %{
      state
      | generation: generation,
        timer: timer,
        failures: if(state.loaded, do: 0, else: min(state.failures + 1, 6))
    }
  end

  defp publish(state),
    do:
      :ets.insert(
        state.table,
        {:route, %{owner: self(), ready: state.ready, endpoint: state.endpoint}}
      )

  @impl true
  def terminate(_, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    if state.job, do: Process.exit(state.job.pid, :kill)
  end
end
