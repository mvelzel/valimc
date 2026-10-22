defmodule Valimc.Net.LoginJobs do
  @moduledoc """
  Cold-path login jobs (VMC-077r): RSA key exchange (`:key`, at most
  `:crypto_workers`) and session verification (`:session`, at most
  `:authentication_workers`), one bounded pool each. A job waits for its
  owner's `activate/1`, runs once and sends `{reply, pid, token, result}`; it
  ends at its deadline, and its pool kills it when its owner goes, so an
  abrupt socket loss frees its slot at once. Admission is a call bounded by
  `:admission_call_ms`: a stalled pool refuses rather than blocking a login.
  """
  use GenServer
  alias Valimc.Protocol.Encryption

  @kinds %{
    key: %{
      name: Valimc.KeyExchangeJobs,
      limit: :crypto_workers,
      timeout: :key_exchange_timeout_ms,
      reply: :key_verified,
      busy: :key_workers_busy
    },
    session: %{
      name: Valimc.SessionJobs,
      limit: :authentication_workers,
      timeout: :authentication_timeout_ms,
      reply: :session_verified,
      busy: :authentication_busy
    }
  }

  @doc "The registered pool of `kind`."
  def pool(kind), do: @kinds[kind].name

  def child_spec(kind),
    do: %{id: {__MODULE__, kind}, start: {__MODULE__, :start_link, [kind]}}

  def start_link(kind), do: GenServer.start_link(__MODULE__, kind, name: pool(kind))

  @doc "Verify the client's encryption response with the server's key `pair`."
  def key_exchange(owner, token, pair, challenge, body),
    do:
      start(:key, owner, token, fn _deadline ->
        Encryption.accept_response(pair, challenge, body)
      end)

  @doc "Ask the session service whether `name` joined with `digest`."
  def session(owner, token, name, digest) do
    service = Valimc.config(:session_service)
    start(:session, owner, token, &service.lookup(name, digest, &1))
  end

  defp start(kind, owner, token, work) do
    %{name: name, timeout: timeout, busy: busy} = @kinds[kind]
    deadline = System.monotonic_time(:millisecond) + Valimc.config(timeout)
    admit(name, busy, {:start, owner, token, work, deadline})
  end

  defp admit(name, busy, request) do
    case GenServer.call(name, request, Valimc.config(:admission_call_ms)) do
      {:ok, job} -> {:ok, Map.put(job, :monitor, Process.monitor(job.pid))}
      error -> error
    end
  catch
    :exit, _ -> {:error, busy}
  end

  def activate(job), do: send(job.pid, {:verify, job.token})

  def cancel(job) do
    Process.exit(job.pid, :kill)
    GenServer.cast(job.pool, {:cancel, job.pid, job.token})
  end

  @impl true
  def init(kind) do
    Process.flag(:trap_exit, true)
    kind = @kinds[kind]
    {:ok, %{jobs: %{}, limit: Valimc.config(kind.limit), kind: kind}}
  end

  @impl true
  def handle_call({:start, owner, token, work, deadline}, {owner, _}, state) do
    if map_size(state.jobs) >= state.limit or not Process.alive?(owner) or
         System.monotonic_time(:millisecond) >= deadline do
      {:reply, {:error, state.kind.busy}, state}
    else
      reply = state.kind.reply

      {pid, ref} =
        :erlang.spawn_opt(
          fn ->
            timeout = max(deadline - System.monotonic_time(:millisecond), 0)

            receive do
              {:verify, ^token} -> send(owner, {reply, self(), token, work.(deadline)})
            after
              timeout -> :ok
            end
          end,
          [:link, :monitor]
        )

      owner_ref = Process.monitor(owner)
      record = %{ref: ref, owner_ref: owner_ref, token: token}
      job = %{pid: pid, token: token, deadline: deadline, pool: state.kind.name}
      {:reply, {:ok, job}, %{state | jobs: Map.put(state.jobs, pid, record)}}
    end
  end

  def handle_call(_, _, state), do: {:reply, {:error, state.kind.busy}, state}

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
