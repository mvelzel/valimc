defmodule Valimc.World.RandomSequences do
  @moduledoc """
  The server's random sequences (VMC-044b1), vanilla's `RandomSequences`:
  one Xoroshiro source per sequence id, first seeded from the world seed,
  the salt (0) and the id's hash, shared by every dimension. Trade sets draw
  from them (`MinecraftServer.getRandomSequence`).

  One owner per world holds them. A group borrows a sequence for one draw
  (`with/3`): the owner hands its state to one lessee at a time and the next
  caller waits for the return, so two groups never draw the same numbers. A
  lessee that dies before returning leaves the sequence as it was. Returned
  states are written to the world's `random_sequences.json` by a task, at
  most once a second, never by the lessee: a crash may replay a second of
  draws (as vanilla replays them since its last save), which changes which
  offers a merchant gets, never an item anyone holds.
  """
  use GenServer

  @file_name "random_sequences.json"
  @write_after 1_000
  # Callers waiting for a leased sequence, at most (one per group at a time).
  @max_waiting 1_024

  @doc """
  Run `fun.(state)` on sequence `id`'s state (`{lo, hi}`); `fun` answers
  `{result, new_state}` (the state after its draws) or `{result,
  :unchanged}`. `{:ok, result}`, or `{:error, {:retry, reason}}` when the
  owner is busy or gone.
  """
  def with(server \\ __MODULE__, id, fun) when is_binary(id) and is_function(fun, 1) do
    case lease(server, id) do
      {:ok, ref, state} ->
        {result, next} =
          try do
            fun.(state)
          catch
            kind, reason ->
              GenServer.cast(server, {:release, ref, :unchanged})
              :erlang.raise(kind, reason, __STACKTRACE__)
          end

        GenServer.cast(server, {:release, ref, next})
        {:ok, result}

      {:error, _} = error ->
        error
    end
  end

  defp lease(server, id) do
    GenServer.call(server, {:lease, id}, 5_000)
  catch
    :exit, _ -> {:error, {:retry, :random_sequences_unavailable}}
  end

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "The sequences saved in the world at `base`: `{:ok, %{id => {lo, hi}}}` or why they do not read."
  def read(nil), do: {:ok, %{}}

  def read(base) do
    path = Path.join(base, @file_name)

    case File.read(path) do
      {:ok, text} ->
        with {:ok, %{"salt" => 0, "sequences" => sequences}} when is_map(sequences) <-
               JSON.decode(text),
             true <-
               Enum.all?(sequences, fn {_, v} ->
                 match?([lo, hi] when is_integer(lo) and is_integer(hi), v)
               end) do
          {:ok, Map.new(sequences, fn {id, [lo, hi]} -> {id, {lo, hi}} end)}
        else
          _ -> {:error, {:invalid_random_sequences, path}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:random_sequences_unreadable, path, reason}}
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    base = Keyword.get(opts, :dir, Valimc.config(:world_path))

    case read(base) do
      {:ok, sequences} ->
        {:ok,
         %{
           base: base,
           seed: Keyword.get(opts, :seed),
           sequences: sequences,
           leases: %{},
           waiting: %{},
           waiting_count: 0,
           dirty: false,
           timer: nil,
           writer: nil
         }}

      {:error, reason} ->
        {:stop, {:random_sequences_unavailable, reason}}
    end
  end

  @impl true
  def handle_call({:lease, id}, {pid, _} = from, state) do
    cond do
      Enum.any?(state.leases, fn {_, {lease_id, _, _}} -> lease_id == id end) ->
        if state.waiting_count >= @max_waiting do
          {:reply, {:error, {:retry, :random_sequences_busy}}, state}
        else
          waiting = Map.update(state.waiting, id, :queue.from_list([from]), &:queue.in(from, &1))
          {:noreply, %{state | waiting: waiting, waiting_count: state.waiting_count + 1}}
        end

      true ->
        {ref, sequence, state} = grant(state, id, pid)
        {:reply, {:ok, ref, sequence}, state}
    end
  end

  @impl true
  def handle_cast({:release, ref, next}, state) do
    case Map.pop(state.leases, ref) do
      {{id, _, monitor}, leases} ->
        Process.demonitor(monitor, [:flush])
        state = %{state | leases: leases}

        state =
          case next do
            {lo, hi} when is_integer(lo) and is_integer(hi) ->
              schedule_write(%{
                state
                | sequences: Map.put(state.sequences, id, {lo, hi}),
                  dirty: true
              })

            :unchanged ->
              state
          end

        {:noreply, serve(state, id)}

      {nil, _} ->
        {:noreply, state}
    end
  end

  @impl true
  # A failed write tries again.
  def handle_info({:DOWN, ref, :process, _, _}, %{writer: {ref, _}} = state),
    do: {:noreply, schedule_write(%{state | writer: nil, dirty: true})}

  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Enum.find(state.leases, fn {_, {_, _, m}} -> m == monitor end) do
      {ref, {id, _, _}} -> {:noreply, serve(%{state | leases: Map.delete(state.leases, ref)}, id)}
      nil -> {:noreply, state}
    end
  end

  def handle_info(:write, state), do: {:noreply, write(%{state | timer: nil})}

  def handle_info({ref, _result}, %{writer: {ref, _}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     if(state.dirty, do: schedule_write(%{state | writer: nil}), else: %{state | writer: nil})}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.dirty and state.base, do: encode_write(state.base, state.sequences)
    :ok
  end

  defp grant(state, id, pid) do
    sequence =
      Map.get_lazy(state.sequences, id, fn ->
        seed = state.seed || Valimc.World.Spec.current().seed
        Valimc.Native.loot_sequence(seed, 0, id)
      end)

    ref = make_ref()
    monitor = Process.monitor(pid)

    {ref, sequence,
     %{
       state
       | leases: Map.put(state.leases, ref, {id, pid, monitor}),
         sequences: Map.put(state.sequences, id, sequence)
     }}
  end

  # The next caller waiting for `id`, if any, takes it.
  defp serve(state, id) do
    case Map.get(state.waiting, id) do
      nil ->
        state

      queue ->
        {{:value, {pid, _} = from}, rest} = :queue.out(queue)

        waiting =
          if :queue.is_empty(rest),
            do: Map.delete(state.waiting, id),
            else: Map.put(state.waiting, id, rest)

        state = %{state | waiting: waiting, waiting_count: state.waiting_count - 1}

        if Process.alive?(pid) do
          {ref, sequence, state} = grant(state, id, pid)
          GenServer.reply(from, {:ok, ref, sequence})
          state
        else
          serve(state, id)
        end
    end
  end

  defp schedule_write(%{base: nil} = state), do: %{state | dirty: false}

  defp schedule_write(%{timer: nil, writer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :write, @write_after)}

  defp schedule_write(state), do: state

  defp write(%{dirty: false} = state), do: state
  defp write(%{writer: {_, _}} = state), do: state

  defp write(state) do
    %{base: base, sequences: sequences} = state

    task =
      Task.Supervisor.async_nolink(Valimc.TransferWorkers, fn -> encode_write(base, sequences) end)

    %{state | writer: {task.ref, sequences}, dirty: false}
  end

  defp encode_write(base, sequences) do
    json =
      JSON.encode!(%{
        "salt" => 0,
        "sequences" => Map.new(sequences, fn {id, {lo, hi}} -> {id, [lo, hi]} end)
      })

    :ok = Valimc.Storage.DurableFile.write(Path.join(base, @file_name), json)
  end
end
