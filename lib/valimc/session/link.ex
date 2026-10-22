defmodule Valimc.Session.Link do
  @moduledoc """
  The connection's half of a playing session (VMC-077i3). At the end of
  login the connection hands the session (`Valimc.Session.Host`) to the group
  that owns the player's section and keeps the socket, framing, encryption,
  compression, keepalive, the chunk view and streaming, and the replication
  that reads publications: peers, entities, clocks, weather, border and
  difficulty.

  The connection stays the player's address. Play packets other than its own
  (keepalive, chunk acknowledgements, client information) go to the owner as
  `{:player, uuid, {:input, id, payload}}`; every message that is not the
  connection's own goes there too. The owner sends back
  `{:player_out, items}`: frames to write and view changes (the player's
  pose and teleport state, a view reset on respawn or travel), in order.
  """
  alias Valimc.Net.Codec
  alias Valimc.Protocol.{EntityPackets, Packets}
  alias Valimc.Session.{ChunkSender, Events, Messages, Replication}
  alias Valimc.{Players, World}
  alias Valimc.World.{ChestLidReplication, EntityReplication}

  # What only the connection keeps; the session keeps the rest.
  @link_keys [
    :step,
    :protocol,
    :buffer,
    :cipher,
    :encryption_requested,
    :online_mode,
    :login_name,
    :key_challenge,
    :key_pair,
    :key_public,
    :key_job,
    :auth_job,
    :window,
    :packets,
    :bytes,
    :logical_bytes,
    :keepalive,
    :active,
    :chunks,
    :regions,
    :wanted,
    :pending,
    :chunk_sender,
    :requested_view_distance,
    :view,
    :peers,
    :entity_replication,
    :entity_cache,
    :clock_version,
    :weather_view,
    :difficulty_view,
    :border_view,
    :chest_lids,
    :outbound
  ]
  @shared_keys [:socket, :connection, :phase, :threshold, :teleport_pending]
  @player_keys [:pid, :uuid, :name, :entity_id, :x, :y, :z, :yaw, :pitch, :dimension]

  # Region events (`Valimc.World.publish/2`) a session acts on too.
  @session_events [
    :table_admitted,
    :container_changed,
    :container_progress,
    :container_closed,
    :block,
    :block_batch
  ]

  @doc """
  Hand the session in `state` to its section's group: the connection's state
  after login. A world that cannot host it refuses the login.
  """
  def host(state) do
    %{x: x, z: z, dimension: dimension} = state.player
    session = session(state)

    with {:ok, {pid, _}} <- World.owner(World.section(dimension, World.chunk_key(x, z))),
         :ok <- host_call(pid, session) do
      link = Map.take(state, @link_keys ++ @shared_keys)

      Map.merge(link, %{
        player: Map.take(state.player, @player_keys),
        owner: pid,
        owner_monitor: Process.monitor(pid)
      })
    else
      _ -> Codec.reject(state, "World unavailable; please retry")
    end
  end

  defp host_call(pid, session) do
    GenServer.call(pid, {:host_player, session}, 15_000)
  catch
    :exit, _ -> {:error, :owner_unavailable}
  end

  @doc "The session part of a connection's state, as its group hosts it."
  def session(state) do
    state
    |> Map.drop(@link_keys)
    |> Map.merge(%{socket: nil, inputs: :queue.new(), pickup_cache: %{}})
  end

  @doc """
  The session rebuilds its client's level (a respawn or a travel): its
  connection resets the view in order with the session's packets. `reset`
  names the new `dimension`, whether the old level is unloaded chunk by chunk
  (`unload`), and the clock, difficulty, weather and border views the session
  sends with the respawn.
  """
  def reset_view(%{socket: nil}, reset), do: Valimc.Session.Host.out({:reset, reset})

  @doc "A message to a connection whose session its group hosts."
  def info({:player_out, items}, state),
    do: Valimc.Connection.guard_connection(state, fn -> {:noreply, apply_out(state, items)} end)

  def info({:player_owner, uuid, pid}, %{player: %{uuid: uuid}} = state) do
    if pid == state.owner do
      {:noreply, state}
    else
      Process.demonitor(state.owner_monitor, [:flush])
      {:noreply, %{state | owner: pid, owner_monitor: Process.monitor(pid)}}
    end
  end

  def info({:player_stop, reason}, state) do
    if reason != nil, do: Valimc.Session.Presence.record(reason)
    Process.demonitor(state.owner_monitor, [:flush])
    {:stop, :normal, %{state | owner: nil, owner_monitor: nil}}
  end

  def info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state) do
    Valimc.Connection.guard_connection(%{state | owner: nil, owner_monitor: nil}, fn ->
      Codec.reject(%{state | owner: nil}, "World owner restarted; please reconnect")
    end)
  end

  def info({:DOWN, ref, :process, pid, _} = message, state) do
    case Replication.chunk_reply(state, message) do
      {:ok, state} ->
        {:noreply, state}

      :error ->
        {lids, closed} = ChestLidReplication.down(state.chest_lids, ref, pid)
        Codec.send_packets(state, Enum.map(closed, &Packets.chest_lid(&1, false)))
        {:noreply, %{state | chest_lids: lids}}
    end
  end

  def info({[:alias | ref], _} = message, state) when is_reference(ref),
    do: Messages.info(message, state)

  def info(:send_chunks, state), do: Messages.info(:send_chunks, state)

  def info(:publish_movement, state) do
    forward(state, :publish_movement)

    Valimc.Connection.guard_connection(state, fn ->
      Process.send_after(self(), :publish_movement, 50)
      {:noreply, replicate(state)}
    end)
  end

  def info({:event, {:in_dimension, dimension, event}}, state) do
    if dimension == Valimc.Dimension.current(),
      do: event(state, event, {:event, {:in_dimension, dimension, event}}),
      else: {:noreply, state}
  end

  def info({:event, event}, state), do: event(state, event, {:event, event})

  def info(message, state)
      when is_tuple(message) and elem(message, 0) in [:tcp, :tcp_closed, :tcp_error, :EXIT],
      do: Messages.info(message, state)

  def info(message, state) when message in [:drain, :keepalive],
    do: Messages.info(message, state)

  def info(:login_deadline, state), do: {:noreply, state}

  def info(message, state) do
    forward(state, message)
    {:noreply, state}
  end

  @doc "Send `message` to the session at its owner."
  def forward(state, message) do
    send(state.owner, {:player, state.player.uuid, message})
    :ok
  end

  # A region event: the client's part here (what it has loaded), the
  # session's part at the owner.
  defp event(state, event, message) do
    if is_tuple(event) and elem(event, 0) in @session_events, do: forward(state, message)
    Valimc.Connection.guard_connection(state, fn -> {:noreply, Events.view(state, event)} end)
  end

  defp apply_out(state, items) do
    Enum.reduce(items, state, fn
      {:frames, frames}, acc ->
        Codec.send_frames(acc, frames)
        acc

      {:view, view}, acc ->
        apply_view(acc, view)

      {:reset, reset}, acc ->
        reset(acc, reset)
    end)
  end

  # The player's pose and teleport state, as the owner last saw them.
  defp apply_view(state, view) do
    if view.dimension != state.player.dimension, do: Valimc.Dimension.put(view.dimension)
    confirmed = state.teleport_pending and not view.teleport_pending

    state = %{
      state
      | player: Map.merge(state.player, Map.delete(view, :teleport_pending)),
        teleport_pending: view.teleport_pending
    }

    state = Replication.update_view(state)
    if confirmed, do: Replication.stream_chunks(state), else: state
  end

  # A respawn or a travel: the client forgets its level (`unload`: chunk by
  # chunk, peers and entities too); the view starts over in `dimension`.
  defp reset(state, reset) do
    if reset.unload do
      old_entities = Enum.map(state.peers, fn {_, view} -> Packets.remove_entity(view) end)
      old_items = Map.keys(state.entity_replication.tracked)
      old_items = if old_items == [], do: [], else: [EntityPackets.remove(old_items)]

      Codec.send_packets(
        state,
        Enum.map(state.chunks, &Packets.unload/1) ++ old_entities ++ old_items
      )
    end

    regions =
      if reset.dimension != state.player.dimension do
        World.subscribe(MapSet.new(), state.regions)
        Valimc.Dimension.put(reset.dimension)
        MapSet.new()
      else
        state.regions
      end

    %{
      state
      | player: %{state.player | dimension: reset.dimension},
        view: nil,
        regions: regions,
        chunks: MapSet.new(),
        pending: [],
        chunk_sender: ChunkSender.reset(state.chunk_sender),
        peers: %{},
        chest_lids: %ChestLidReplication{},
        entity_replication: EntityReplication.new(),
        entity_cache: %{},
        clock_version: reset.clock_version,
        difficulty_view: reset.difficulty,
        weather_view: reset.weather,
        border_view: reset.border
    }
  end

  # Vanilla tracking ranges, in chunks, of the entity kinds regions own (VMC-070).
  @tracking_ranges %{
    item: Valimc.Protocol.EntityTypes.tracking_range("item"),
    orb: Valimc.Protocol.EntityTypes.tracking_range("experience_orb")
  }
  @entity_range @tracking_ranges |> Map.values() |> Enum.max()

  # The connection's 50 ms replication: chunks, peers, entities and the
  # world's clocks, weather, border and difficulty, as one write.
  defp replicate(state) do
    state = Replication.chunk_tick(state)
    nearby = Players.nearby(state.regions)
    state = Enum.reduce(nearby, state, &Replication.replicate_peer(&2, &1))

    state =
      Enum.reduce(state.peers, state, fn {pid, player}, acc ->
        if MapSet.member?(nearby, pid),
          do: acc,
          else: %{
            Replication.emit_peer_packets(
              acc,
              [Packets.remove_entity(player), Packets.remove_info(player)],
              :buffer
            )
            | peers: Map.delete(acc.peers, pid)
          }
      end)

    # One tracker for every entity kind; unchanged chunks are not re-read. Only
    # entities within vanilla's tracking range of their type are seen.
    {desired, cache} =
      World.visible_entities(
        state.regions,
        Replication.entity_chunks(state, @entity_range),
        state.entity_cache
      )

    desired =
      for {_, %{kind: kind, at: {x, _, z}}} = entry <- desired,
          Replication.sees?(state, {x, z}, @tracking_ranges[kind]),
          into: %{},
          do: entry

    {replication, packets} =
      EntityReplication.reconcile(state.entity_replication, desired, fn region, last ->
        World.entity_frames(World.section(state.player.dimension, region, :section), last)
      end)

    state =
      Replication.emit_peer_packets(
        %{state | entity_replication: replication, entity_cache: cache},
        packets,
        :buffer
      )

    state = Replication.replicate_world(state)
    Codec.send_packets(state, state.outbound |> Enum.reverse() |> List.flatten())
    %{state | outbound: []}
  end
end
