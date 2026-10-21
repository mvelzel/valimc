defmodule Valimc.World.Directory do
  use GenServer
  require Logger
  alias Valimc.World.Region

  @moduledoc """
  Cold resource admission; protected ETS serves gameplay routing without mailbox calls.

  A region whose owner dies before it finished loading is not admitted again at
  once: each consecutive load failure doubles a per-key backoff (from 50 ms), and
  after five in a row the key is poisoned with one error log line and probed again
  only every five minutes. A successful load clears the record. Admission errors are values.
  """
  @table Valimc.RegionRoutes
  @first_backoff_ms 50
  @poison_after 5
  @poison_backoff_ms 300_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Rows are keyed by the region key scoped by the caller's dimension
  # (`Valimc.Dimension.scope/1`, VMC-026b).
  def lookup(key) do
    scoped = Valimc.Dimension.scope(key)

    case :ets.lookup(@table, scoped) do
      [{^scoped, pid, token, _monitor, publication}] -> {pid, token, publication}
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @doc "`{:ok, pid}` of the key's owner, started if needed, or `{:error, reason}`."
  def admit(key) do
    GenServer.call(
      __MODULE__,
      {:admit, Valimc.Dimension.scope(key)},
      5000 * Valimc.config(:owner_call_scale)
    )
  catch
    :exit, _ -> Valimc.Error.retry(:directory_unavailable)
  end

  def publish(key, token, publication),
    do: GenServer.call(__MODULE__, {:publish, Valimc.Dimension.scope(key), token, publication})

  @doc """
  An idle owner is unloading (VMC-077e): its route goes, so admission waits for
  its exit instead of handing out a process that is saving and stopping.
  """
  def retire(key, token),
    do: GenServer.call(__MODULE__, {:retire, Valimc.Dimension.scope(key), token})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{owners: %{}, failures: %{}, retiring: %{}}}
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
        {:publish, key, token, %{epoch: epoch, items: table} = publication},
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

  def handle_call({:retire, key, token}, {pid, _}, state) do
    case :ets.lookup(@table, key) do
      [{^key, ^pid, ^token, monitor, _}] ->
        :ets.delete(@table, key)
        {:reply, :ok, %{state | retiring: Map.put(state.retiring, key, monitor)}}

      _ ->
        {:reply, {:error, :stale_admission}, state}
    end
  end

  defp admit_new(key, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      Map.has_key?(state.retiring, key) ->
        {:reply, Valimc.Error.retry(:region_restarting), state}

      match?(%{until: until} when until > now, state.failures[key]) ->
        if state.failures[key].count >= @poison_after,
          do: {:reply, Valimc.Error.reject({:region_load, :poisoned}), state},
          else: {:reply, Valimc.Error.retry({:region_load, :backoff}), state}

      map_size(state.owners) >= Valimc.config(:max_regions) ->
        {:reply, Valimc.Error.retry(:max_children), state}

      true ->
        start_owner(key, state)
    end
  end

  defp start_owner(key, state) do
    token = make_ref()

    case DynamicSupervisor.start_child(Valimc.RegionSupervisor, {Region, {key, token}}) do
      {:ok, pid} ->
        monitor = Process.monitor(pid)
        :ets.insert(@table, {key, pid, token, monitor, :loading})
        {:reply, {:ok, pid}, %{state | owners: Map.put(state.owners, monitor, {key, pid, token})}}

      {:error, {:already_started, _}} ->
        # An existing name without our admission is never granted fresh authority.
        {:reply, Valimc.Error.retry(:region_restarting), state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  # An owner that died before publishing failed to load.
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
    case state.owners[monitor] do
      {key, ^pid, token} ->
        state = %{
          state
          | owners: Map.delete(state.owners, monitor),
            retiring: Map.reject(state.retiring, fn {_, m} -> m == monitor end)
        }

        case :ets.lookup(@table, key) do
          [{^key, ^pid, ^token, ^monitor, :loading}] ->
            :ets.delete(@table, key)
            {:noreply, failed(state, key, reason)}

          [{^key, ^pid, ^token, ^monitor, _}] ->
            :ets.delete(@table, key)
            {:noreply, state}

          _ ->
            {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end
end
