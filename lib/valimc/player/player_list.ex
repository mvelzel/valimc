defmodule Valimc.Player.PlayerList do
  use GenServer

  @moduledoc "Admission and lifecycle only. Spatial updates and packet traffic bypass this process."
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def join(player, bypass_limit \\ false),
    do: GenServer.call(__MODULE__, {:join, player, bypass_limit})

  def ready(pid), do: GenServer.call(__MODULE__, {:ready, pid})
  def count, do: :ets.info(__MODULE__, :size)
  def all, do: for({_, player} <- :ets.tab2list(__MODULE__), player.ready, do: player)

  def update(pid, player) do
    [{^pid, previous}] = :ets.lookup(__MODULE__, pid)
    :ets.update_element(__MODULE__, pid, {2, player})
    old_key = spatial_key(previous)
    new_key = spatial_key(player)

    if old_key != new_key do
      :ets.insert(Valimc.SpatialIndex, {new_key, pid})
      :ets.delete_object(Valimc.SpatialIndex, {old_key, pid})
    end

    :ok
  end

  @doc "Players in the sections `regions` (routing keys)."
  def nearby(regions) do
    Enum.reduce(regions, MapSet.new(), fn {_, _, _} = key, players ->
      Enum.reduce(:ets.lookup(Valimc.SpatialIndex, key), players, fn {_, pid}, acc ->
        MapSet.put(acc, pid)
      end)
    end)
  end

  @doc """
  Players that may see `player`: those in the sections within the server's
  view distance of it. Each one's connection still checks that it tracks
  `player` before it sends anything about it.
  """
  def around(%{x: x, z: z} = player) do
    view = {Valimc.Data.Grid.chunk_key(x, z), Valimc.Player.ChunkView.server_distance()}
    nearby(Valimc.Player.ChunkView.regions(view, Map.get(player, :dimension, :overworld)))
  end

  def get(pid) do
    case :ets.lookup(__MODULE__, pid) do
      [{_, %{ready: true} = player}] -> {:ok, player}
      _ -> :error
    end
  end

  # The section the player is in (VMC-026b, VMC-077j).
  defp spatial_key(player),
    do:
      Valimc.Data.Grid.section(
        Map.get(player, :dimension, :overworld),
        Valimc.Data.Grid.chunk_key(player.x, player.z)
      )

  def broadcast(event, except \\ nil) do
    # Select only ready pids; copying every full player map would make chat O(N * state).
    for pid <- :ets.select(__MODULE__, [{{:"$1", %{ready: true}}, [], [:"$1"]}]),
        pid != except,
        do: deliver(pid, event)

    :ok
  end

  @doc """
  Send `event` to an online player's process. A mailbox over `:max_mailbox`
  is a client too slow to keep up: its first sender asks it to stop
  (`{:shutdown, :overloaded}`, so its final save runs) and kills it if it
  cannot; `:overloaded` or `:closed` otherwise.
  """
  def deliver(pid, event) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} ->
        if size <= Valimc.config(:max_mailbox) do
          send(pid, {:event, event})
          :ok
        else
          # First sender only: ask for a graceful stop (terminate/2 saves), and kill
          # it if it is too stuck to handle the signal.
          if :ets.insert_new(Valimc.OverloadedConnections, {pid}) do
            Valimc.Data.Metrics.add(:slow_clients_disconnected)
            Process.exit(pid, {:shutdown, :overloaded})
            :timer.kill_after(Valimc.config(:overload_kill_ms), pid)
          end

          :overloaded
        end

      nil ->
        :closed
    end
  end

  @impl true
  def init(_) do
    :ets.new(__MODULE__, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(Valimc.OverloadedConnections, [:named_table, :public, :set, write_concurrency: true])

    :ets.new(Valimc.SpatialIndex, [
      :named_table,
      :public,
      :bag,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{names: %{}, monitors: %{}}}
  end

  defp same_profile?(pid, uuid) do
    case :ets.lookup(__MODULE__, pid) do
      [{^pid, %{uuid: ^uuid}}] -> true
      _ -> false
    end
  end

  @impl true
  def handle_call({:join, player, bypass_limit}, _from, state) do
    key = String.downcase(player.name)

    existing = state.names[key]

    cond do
      # The same profile again (VMC-010e): the caller replaces that session.
      existing != nil and same_profile?(existing, player.uuid) ->
        {:reply, {:error, {:duplicate, existing}}, state}

      existing != nil ->
        {:reply, {:error, "That name is already connected"}, state}

      count() >= Valimc.config(:max_players) and not bypass_limit ->
        {:reply, {:error, :full}, state}

      true ->
        ref = Process.monitor(player.pid)
        :ets.insert(__MODULE__, {player.pid, player})

        {:reply, :ok,
         %{
           state
           | names: Map.put(state.names, key, player.pid),
             monitors: Map.put(state.monitors, ref, key)
         }}
    end
  end

  def handle_call({:ready, pid}, _from, state) do
    [{^pid, player}] = :ets.lookup(__MODULE__, pid)
    existing = all()
    player = %{player | ready: true}
    :ets.insert(__MODULE__, {pid, player})
    :ets.insert(Valimc.SpatialIndex, {spatial_key(player), pid})

    for other <- existing do
      deliver(other.pid, {:player_joined, player})
    end

    {:reply, existing, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    :ets.delete(Valimc.OverloadedConnections, pid)
    :ets.match_delete(Valimc.SpatialIndex, {:_, pid})

    case :ets.take(__MODULE__, pid) do
      [{_, %{ready: true} = player}] -> broadcast({:player_left, player})
      _ -> :ok
    end

    {key, monitors} = Map.pop(state.monitors, ref)
    {:noreply, %{state | monitors: monitors, names: Map.delete(state.names, key)}}
  end
end
