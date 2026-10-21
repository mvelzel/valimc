defmodule Valimc.Players do
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
    if previous.ready, do: publish_replica(player)
    old_key = spatial_key(previous)
    new_key = spatial_key(player)

    if old_key != new_key do
      :ets.insert(Valimc.SpatialIndex, {new_key, pid})
      :ets.delete_object(Valimc.SpatialIndex, {old_key, pid})
    end

    :ok
  end

  def nearby(regions) do
    Enum.reduce(regions, MapSet.new(), fn key, players ->
      Enum.reduce(:ets.lookup(Valimc.SpatialIndex, key), players, fn {_, pid}, acc ->
        MapSet.put(acc, pid)
      end)
    end)
  end

  # Replication reads a 22-word view per known peer each tick, and the slim replica
  # only when that view changed; full maps are read only for newly visible peers.
  @replica_keys [
    :pid,
    :entity_id,
    :uuid,
    :name,
    :x,
    :y,
    :z,
    :yaw,
    :pitch,
    :pose,
    :health,
    :equipment,
    :use_flags,
    :absorption,
    :fire_ticks,
    :environment
  ]

  defp publish_replica(player) do
    replica =
      player
      |> Map.take(@replica_keys)
      |> Map.put(:input, %{
        shared_flags: Map.get(player, :input, %Valimc.PlayerInput{}).shared_flags
      })
      |> Map.put(:motion, %{swimming: Map.get(player, :motion, %Valimc.PlayerMotion{}).swimming})

    :ets.insert(Valimc.PeerViews, {player.pid, Valimc.Protocol.Packets.view(player), replica})
  end

  @doc "The current replication view of a ready peer, or nil."
  def peer_view(pid) do
    :ets.lookup_element(Valimc.PeerViews, pid, 2)
  rescue
    ArgumentError -> nil
  end

  @doc "The slim replication map of a ready peer, or nil."
  def peer_replica(pid) do
    :ets.lookup_element(Valimc.PeerViews, pid, 3)
  rescue
    ArgumentError -> nil
  end

  def get(pid) do
    case :ets.lookup(__MODULE__, pid) do
      [{_, %{ready: true} = player}] -> {:ok, player}
      _ -> :error
    end
  end

  defp spatial_key(player),
    do: Valimc.World.region_key(Valimc.World.chunk_key(player.x, player.z))

  def broadcast(event, except \\ nil) do
    # Select only ready pids; copying every full player map would make chat O(N * state).
    for pid <- :ets.select(__MODULE__, [{{:"$1", %{ready: true}}, [], [:"$1"]}]),
        pid != except,
        do: Valimc.Connection.deliver(pid, event)

    :ok
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

    :ets.new(Valimc.PeerViews, [
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

  @impl true
  def handle_call({:join, player, bypass_limit}, _from, state) do
    key = String.downcase(player.name)

    cond do
      count() >= Valimc.config(:max_players) and not bypass_limit ->
        {:reply, {:error, :full}, state}

      Map.has_key?(state.names, key) ->
        {:reply, {:error, "That name is already connected"}, state}

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
    publish_replica(player)
    :ets.insert(Valimc.SpatialIndex, {spatial_key(player), pid})

    for other <- existing do
      Valimc.Connection.deliver(other.pid, {:player_joined, player})
    end

    {:reply, existing, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    :ets.delete(Valimc.OverloadedConnections, pid)
    :ets.delete(Valimc.PeerViews, pid)
    :ets.match_delete(Valimc.SpatialIndex, {:_, pid})

    case :ets.take(__MODULE__, pid) do
      [{_, %{ready: true} = player}] -> broadcast({:player_left, player})
      _ -> :ok
    end

    {key, monitors} = Map.pop(state.monitors, ref)
    {:noreply, %{state | monitors: monitors, names: Map.delete(state.names, key)}}
  end
end
