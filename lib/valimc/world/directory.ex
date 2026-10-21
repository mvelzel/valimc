defmodule Valimc.World.Directory do
  use GenServer
  alias Valimc.World.Region

  @moduledoc "Cold resource admission; protected ETS serves gameplay routing without mailbox calls."
  @table Valimc.RegionRoutes

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

  def admit(key), do: GenServer.call(__MODULE__, {:admit, Valimc.Dimension.scope(key)})

  def publish(key, token, publication),
    do: GenServer.call(__MODULE__, {:publish, Valimc.Dimension.scope(key), token, publication})

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :protected, read_concurrency: true])
    {:ok, %{owners: %{}}}
  end

  @impl true
  def handle_call({:admit, key}, _from, state) do
    case :ets.lookup(@table, key) do
      [{^key, pid, _, _, _} = row] ->
        if Process.alive?(pid),
          do: {:reply, {:ok, pid}, state},
          else: start_owner(key, forget(row, state))

      [] ->
        start_owner(key, state)
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
          {:reply, :ok, state}
        else
          {:reply, {:error, :invalid_publication}, state}
        end

      _ ->
        {:reply, {:error, :stale_admission}, state}
    end
  end

  def handle_call({:publish, _, _, _}, _, state),
    do: {:reply, {:error, :invalid_publication}, state}

  defp start_owner(key, state) do
    if map_size(state.owners) >= Valimc.config(:max_regions) do
      {:reply, {:error, :max_children}, state}
    else
      token = make_ref()

      case DynamicSupervisor.start_child(Valimc.RegionSupervisor, {Region, {key, token}}) do
        {:ok, pid} ->
          monitor = Process.monitor(pid)
          :ets.insert(@table, {key, pid, token, monitor, :loading})

          {:reply, {:ok, pid},
           %{state | owners: Map.put(state.owners, monitor, {key, pid, token})}}

        {:error, {:already_started, _}} ->
          # An existing name without our admission is never granted fresh authority.
          {:reply, {:error, :region_restarting}, state}

        error ->
          {:reply, error, state}
      end
    end
  end

  defp forget({key, _pid, _token, monitor, _publication}, state) do
    :ets.delete(@table, key)
    Process.demonitor(monitor, [:flush])
    %{state | owners: Map.delete(state.owners, monitor)}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, pid, _}, state) do
    case state.owners[monitor] do
      {key, ^pid, token} ->
        if Process.alive?(pid) do
          {:noreply, state}
        else
          case :ets.lookup(@table, key) do
            [{^key, ^pid, ^token, ^monitor, _} = row] -> {:noreply, forget(row, state)}
            _ -> {:noreply, %{state | owners: Map.delete(state.owners, monitor)}}
          end
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}
end
