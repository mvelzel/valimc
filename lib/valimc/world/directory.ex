defmodule Valimc.World.Directory do
  use GenServer
  require Logger
  alias Valimc.World.Region

  @moduledoc """
  Cold resource admission; protected ETS serves gameplay routing without mailbox calls.

  Each row maps an 8 × 8 section's key to the group process that owns it
  (VMC-077j), its admission token and what it publishes (its epoch and table).
  A section is admitted into a group of its own; it changes groups only by a
  handoff, whose giving group moves the route (`move/4`) once the adopting
  group owns the section's table and has the section's state in its mailbox:
  a call routed there finds the section, and the route goes with the
  adopter's death, adopted or not.

  A section whose group dies before it finished loading is not admitted again
  at once: each consecutive load failure doubles a per-key backoff (from 50
  ms), and after five in a row the key is poisoned with one error log line and
  probed again only every five minutes. A successful load clears the record.
  Admission errors are values.
  """
  @table Valimc.RegionRoutes
  @first_backoff_ms 50
  @poison_after 5
  @poison_backoff_ms 300_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Rows are keyed by the section key `{dimension, sx, sz}` (VMC-077j).
  def lookup({_, _, _} = key) do
    case :ets.lookup(@table, key) do
      [{^key, pid, token, _monitor, publication}] -> {pid, token, publication}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "`{:ok, pid}` of the key's owner, started if needed, or `{:error, reason}`."
  def admit({_, _, _} = key) do
    GenServer.call(__MODULE__, {:admit, key}, 5000 * Valimc.config(:owner_call_scale))
  catch
    :exit, _ -> Valimc.Data.Error.retry(:directory_unavailable)
  end

  def publish({_, _, _} = key, token, publication),
    do: GenServer.call(__MODULE__, {:publish, key, token, publication})

  @doc """
  The calling group handed section `key` (admitted with `token`) to group
  `target`, which owns its table (in `publication`) now: route it there. The
  route goes with the target's death from now on, adopted or not, so the
  section is admitted again from its log.
  """
  def move({_, _, _} = key, token, target, publication),
    do: GenServer.call(__MODULE__, {:move, key, token, target, publication})

  @doc """
  An idle owner is unloading (VMC-077e): its route goes, so admission waits for
  its exit instead of handing out a process that is saving and stopping.
  """
  def retire({_, _, _} = key, token),
    do: GenServer.call(__MODULE__, {:retire, key, token})

  @doc "The calling group finished retiring `key`: it may be admitted again."
  def retired({_, _, _} = key), do: GenServer.cast(__MODULE__, {:retired, key})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    # monitors: monitor => group pid; groups: pid => {monitor, keys}
    {:ok, %{monitors: %{}, groups: %{}, failures: %{}, retiring: %{}}}
  end

  @impl true
  def handle_call({:admit, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, pid, _, monitor, _}] ->
        if Process.alive?(pid) do
          {:reply, {:ok, pid}, state}
        else
          # Its DOWN is due: handle it first, so a failed load is recorded.
          receive do
            {:DOWN, ^monitor, :process, ^pid, reason} ->
              {:noreply, state} = down(state, monitor, pid, reason)
              admit_new(key, state)
          end
        end

      [] ->
        admit_new(key, state)
    end
  end

  def handle_call(
        {:publish, key, token, %{epoch: epoch, publication: table} = publication},
        {pid, _},
        state
      )
      when is_reference(epoch) and is_reference(table) and map_size(publication) == 2 do
    case :ets.lookup(@table, key) do
      [{^key, ^pid, ^token, monitor, :loading}] ->
        if :ets.info(table, :owner) == pid and :ets.info(table, :protection) == :protected do
          :ets.insert(@table, {key, pid, token, monitor, publication})
          {:reply, :ok, %{state | failures: Map.delete(state.failures, key)}}
        else
          {:reply, {:error, :invalid_publication}, state}
        end

      _ ->
        {:reply, {:error, :stale_admission}, state}
    end
  end

  def handle_call({:publish, _, _, _}, _, state),
    do: {:reply, {:error, :invalid_publication}, state}

  def handle_call(
        {:move, key, token, target, %{publication: table} = publication},
        {from, _},
        state
      ) do
    case :ets.lookup(@table, key) do
      [{^key, ^from, ^token, _, _}] ->
        if :ets.info(table, :owner) == target do
          {monitor, state} = watch(state, target)
          :ets.insert(@table, {key, target, token, monitor, publication})
          {:reply, :ok, state |> forget(from, key) |> remember(target, key)}
        else
          {:reply, {:error, :invalid_publication}, state}
        end

      _ ->
        {:reply, {:error, :stale_admission}, state}
    end
  end

  def handle_call({:retire, key, token}, {pid, _}, state) do
    case :ets.lookup(@table, key) do
      [{^key, ^pid, ^token, _, _}] ->
        :ets.delete(@table, key)
        {:reply, :ok, %{state | retiring: Map.put(state.retiring, key, pid)}}

      _ ->
        {:reply, {:error, :stale_admission}, state}
    end
  end

  @impl true
  def handle_cast({:retired, key}, state),
    do: {:noreply, %{forget_retiring(state, key) | retiring: Map.delete(state.retiring, key)}}

  defp forget_retiring(state, key) do
    case state.retiring do
      %{^key => pid} -> forget(state, pid, key)
      _ -> state
    end
  end

  defp admit_new(key, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      Map.has_key?(state.retiring, key) ->
        {:reply, Valimc.Data.Error.retry(:region_restarting), state}

      match?(%{until: until} when until > now, state.failures[key]) ->
        if state.failures[key].count >= @poison_after,
          do: {:reply, Valimc.Data.Error.reject({:region_load, :poisoned}), state},
          else: {:reply, Valimc.Data.Error.retry({:region_load, :backoff}), state}

      sections(state) >= Valimc.config(:max_regions) ->
        {:reply, Valimc.Data.Error.retry(:max_children), state}

      true ->
        start_owner(key, state)
    end
  end

  defp sections(state),
    do:
      state.groups
      |> Map.values()
      |> Enum.map(fn {_, keys} -> MapSet.size(keys) end)
      |> Enum.sum()

  # A newly admitted section gets a group of its own; the regionizer merges
  # groups (VMC-077j).
  defp start_owner(key, state) do
    token = make_ref()

    case DynamicSupervisor.start_child(Valimc.RegionSupervisor, {Region, {key, token}}) do
      {:ok, pid} ->
        {monitor, state} = watch(state, pid)
        :ets.insert(@table, {key, pid, token, monitor, :loading})
        {:reply, {:ok, pid}, remember(state, pid, key)}

      {:error, {:already_started, _}} ->
        # An existing name without our admission is never granted fresh authority.
        {:reply, Valimc.Data.Error.retry(:region_restarting), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp watch(state, pid) do
    case state.groups do
      %{^pid => {monitor, _}} ->
        {monitor, state}

      _ ->
        monitor = Process.monitor(pid)

        {monitor,
         %{
           state
           | monitors: Map.put(state.monitors, monitor, pid),
             groups: Map.put(state.groups, pid, {monitor, MapSet.new()})
         }}
    end
  end

  defp remember(state, pid, key),
    do: %{
      state
      | groups: Map.update!(state.groups, pid, fn {m, keys} -> {m, MapSet.put(keys, key)} end)
    }

  defp forget(state, pid, key) do
    case state.groups do
      %{^pid => {monitor, keys}} ->
        %{state | groups: Map.put(state.groups, pid, {monitor, MapSet.delete(keys, key)})}

      _ ->
        state
    end
  end

  # A section whose group died before publishing it failed to load.
  defp failed(state, key, reason) do
    now = System.monotonic_time(:millisecond)
    count = Map.get(state.failures, key, %{count: 0}).count + 1

    backoff =
      if count >= @poison_after,
        do: @poison_backoff_ms,
        else: @first_backoff_ms * Integer.pow(2, count - 1)

    if count == @poison_after do
      Logger.error(
        "Region #{inspect(key)} failed to load #{count} times in a row " <>
          "(#{inspect(reason)}); refusing it, retrying every #{div(@poison_backoff_ms, 1000)} s"
      )
    else
      Logger.warning("Region #{inspect(key)} failed to load: #{inspect(reason)}")
    end

    %{state | failures: Map.put(state.failures, key, %{count: count, until: now + backoff})}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, reason}, state),
    do: down(state, monitor, pid, reason)

  def handle_info(_, state), do: {:noreply, state}

  defp down(state, monitor, pid, reason) do
    case state.monitors do
      %{^monitor => ^pid} ->
        {{_, keys}, groups} = Map.pop(state.groups, pid)

        state = %{
          state
          | monitors: Map.delete(state.monitors, monitor),
            groups: groups,
            retiring: Map.reject(state.retiring, fn {_, p} -> p == pid end)
        }

        state =
          Enum.reduce(keys, state, fn key, acc ->
            case :ets.lookup(@table, key) do
              [{^key, ^pid, _, ^monitor, :loading}] ->
                :ets.delete(@table, key)
                failed(acc, key, reason)

              [{^key, ^pid, _, ^monitor, _}] ->
                :ets.delete(@table, key)
                acc

              _ ->
                acc
            end
          end)

        {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end
end
