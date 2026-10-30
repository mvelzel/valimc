defmodule Valimc.Net.Link do
  @moduledoc """
  The connection's half of a playing session (VMC-077i3). At the end of
  login the connection hands the session (`Valimc.Player.Host`) to the group
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
  alias Valimc.Data.Grid
  require Logger
  alias Valimc.Protocol.Codec
  alias Valimc.Protocol.{EntityPackets, Packets}
  alias Valimc.Session.{ChunkSender, EntityMembership, Events, Replication}
  alias Valimc.World
  alias Valimc.World.ChestLidReplication
  alias Valimc.Entity.Observer

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
    :own_chunk_missing,
    :regions,
    :wanted,
    :wanted_owners,
    :view_wants,
    :dragon_arena,
    :generation_focus,
    :pending,
    :chunk_sender,
    :requested_view_distance,
    :view,
    :entity_replication,
    :entity_cache,
    :entity_chunks_cache,
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

    with {:ok, {pid, _}} <-
           World.owner(Grid.section(dimension, Grid.chunk_key(x, z))),
         :ok <- host_call(pid, session) do
      link = Map.take(state, @link_keys ++ @shared_keys)

      Map.merge(link, %{
        player:
          state.player
          |> Map.take(@player_keys)
          |> Map.put(:alive, state.life_stage == :alive)
          |> Map.put(:spectator, state.player.game_mode.current == :spectator),
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

  @doc """
  The session part of a connection's state, as its group hosts it, with the
  router its group runs its messages through (`Valimc.Player.Host`).
  """
  def session(state) do
    state
    |> Map.drop(@link_keys)
    |> Map.merge(%{socket: nil, pickup_cache: %{}, router: Valimc.Session.Messages})
  end

  @doc "A message to a connection whose session its group hosts."
  def info({:player_out, items}, state),
    do: Valimc.Session.Messages.guard(state, fn -> {:noreply, apply_out(state, items)} end)

  def info({:player_owner, uuid, pid}, %{player: %{uuid: uuid}} = state) do
    if pid == state.owner do
      {:noreply, state}
    else
      Process.demonitor(state.owner_monitor, [:flush])
      {:noreply, %{state | owner: pid, owner_monitor: Process.monitor(pid)}}
    end
  end

  def info({:player_stop, reason}, state) do
    if reason != nil, do: Valimc.Protocol.Codec.record_reason(reason)
    Process.demonitor(state.owner_monitor, [:flush])
    {:stop, :normal, %{state | owner: nil, owner_monitor: nil}}
  end

  def info({:DOWN, ref, :process, _, _}, %{owner_monitor: ref} = state) do
    Valimc.Session.Messages.guard(%{state | owner: nil, owner_monitor: nil}, fn ->
      Codec.reject(%{state | owner: nil}, "World owner restarted; please reconnect")
    end)
  end

  def info({:wanted_owner_down, _ref, :process, pid, _}, state),
    do: {:noreply, Replication.owner_down(state, pid)}

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
    do: Valimc.Net.Messages.info(message, state)

  def info(:send_chunks, state), do: Valimc.Net.Messages.info(:send_chunks, state)

  def info(:publish_movement, state) do
    forward(state, :publish_movement)

    Valimc.Session.Messages.guard(state, fn ->
      Process.send_after(self(), :publish_movement, 50)
      {:noreply, replicate(state)}
    end)
  end

  def info({:event, {:in_dimension, dimension, event}}, state) do
    if dimension == Valimc.World.Dimension.current(),
      do: event(state, event, {:event, {:in_dimension, dimension, event}}),
      else: {:noreply, state}
  end

  def info({:event, event}, state), do: event(state, event, {:event, event})

  def info(message, state)
      when is_tuple(message) and elem(message, 0) in [:tcp, :tcp_closed, :tcp_error, :EXIT],
      do: Valimc.Net.Messages.info(message, state)

  def info(message, state) when message in [:drain, :keepalive],
    do: Valimc.Net.Messages.info(message, state)

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
    Valimc.Session.Messages.guard(state, fn -> {:noreply, Events.view(state, event)} end)
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
    if view.dimension != state.player.dimension, do: Valimc.World.Dimension.put(view.dimension)
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
  # chunk, and its entities and players too); the view starts over in
  # `dimension`.
  defp reset(state, reset) do
    if reset.unload do
      old = Map.keys(state.entity_replication.tracked)
      old = if old == [], do: [], else: [EntityPackets.remove(old)]
      Codec.send_packets(state, Enum.map(state.chunks, &Packets.unload/1) ++ old)
    end

    regions =
      if reset.dimension != state.player.dimension do
        World.subscribe(MapSet.new(), state.regions)
        Valimc.World.Dimension.put(reset.dimension)
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
        pending: Valimc.Session.PendingChunks.new(),
        chunk_sender: ChunkSender.reset(state.chunk_sender),
        chest_lids: %ChestLidReplication{},
        entity_replication: Observer.new(),
        entity_cache: %{},
        clock_version: reset.clock_version,
        difficulty_view: reset.difficulty,
        weather_view: reset.weather,
        border_view: reset.border
    }
  end

  # Vanilla tracking ranges, in chunks, of the entity kinds groups own (VMC-070);
  # a body's row carries its type's (VMC-043a), at most the player's.
  @tracking_ranges %{
    item: Valimc.Data.EntityTypes.tracking_range("item"),
    orb: Valimc.Data.EntityTypes.tracking_range("experience_orb"),
    player: Valimc.Data.EntityTypes.tracking_range("player")
  }
  @entity_range @tracking_ranges |> Map.values() |> Enum.max()

  # The connection's 50 ms replication: chunks, entities and players and the
  # world's clocks, weather, border and difficulty, as one write.
  defp replicate(state) do
    state = state |> Replication.chunk_tick() |> own_chunk()

    # One tracker for every entity kind, players included (VMC-077i4);
    # unchanged chunks are not re-read. Only entities within vanilla's
    # tracking range of their type are seen.
    {chunks, state} = Replication.cached_entity_chunks(state, @entity_range)

    cache = state.entity_cache
    {rows, views} = World.entity_rows(state.regions, chunks, Map.get(cache, :views, %{}))

    # Who it observes changes with the rows that changed, or all at once
    # when the player moves or its view or game mode does (VMC-081i).
    key =
      {state.view, state.player.x, state.player.z, Map.get(state.player, :spectator, false),
       state.player.entity_id}

    {membership, desired, touched} =
      EntityMembership.update(
        Map.get(cache, :membership, %EntityMembership{}),
        rows,
        key,
        &visible?(state, &1)
      )

    {replication, packets} =
      Observer.reconcile(state.entity_replication, desired, touched, fn region, last ->
        World.entity_frames(
          Grid.section(state.player.dimension, region, :section),
          last
        )
      end)

    cache = %{views: views, membership: membership}

    state =
      Replication.buffer(%{state | entity_replication: replication, entity_cache: cache}, packets)

    state = Replication.replicate_world(state)
    Codec.send_packets(state, state.outbound |> Enum.reverse() |> List.flatten())
    %{state | outbound: []}
  end

  # The vanilla client draws nothing while it lacks the chunk the player is
  # in. How long that lasts: `own_chunk_missing_ms` in all, `own_chunk_gaps`
  # how often, `own_chunk_missing_max_ms` the longest; a gap over a second is
  # logged with the player's name.
  defp own_chunk(state) do
    here = MapSet.member?(state.chunks, Grid.chunk_key(state.player.x, state.player.z))
    now = System.monotonic_time(:millisecond)

    case {here, state.own_chunk_missing} do
      {false, nil} ->
        %{state | own_chunk_missing: now}

      {true, since} when since != nil ->
        gap = now - since
        Valimc.Data.Metrics.add(:own_chunk_missing_ms, gap)
        Valimc.Data.Metrics.add(:own_chunk_gaps)

        if gap > Valimc.Data.Metrics.get(:own_chunk_missing_max_ms),
          do: Valimc.Data.Metrics.put(:own_chunk_missing_max_ms, gap)

        if gap > 1000,
          do: Logger.info("#{state.player.name} lacked its own chunk for #{gap} ms")

        %{state | own_chunk_missing: nil}

      _ ->
        state
    end
  end

  # Within vanilla's tracking range of its type, and a player only as shown.
  defp visible?(state, %{kind: kind, at: {x, _, z}} = view) do
    Replication.sees?(state, {x, z}, Map.get(view, :range) || @tracking_ranges[kind]) and
      (kind != :player or shows?(state, view))
  end

  # Another online player; a spectator only to spectators, as vanilla's
  # `ServerPlayer.broadcastToPlayer`. A player whose connection is gone may
  # stay published until its group's next tick.
  defp shows?(state, view) do
    view.entity_id != state.player.entity_id and :ets.member(Valimc.Player.PlayerList, view.pid) and
      (not view.spectator or Map.get(state.player, :spectator, false))
  end
end
