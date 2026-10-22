defmodule Valimc.Session.Replication do
  @moduledoc "What a connection's client sees: view distance, chunk streaming and peer player replication (VMC-069, VMC-070)."

  alias Valimc.Protocol.{
    Packets,
    Wire
  }

  import Valimc.Net.Codec,
    only: [send_packets: 2, send_frames: 2]

  alias Valimc.{
    Players,
    World
  }

  alias Valimc.World.{ChestLidReplication, Directory, Region}
  alias Valimc.Session.{ChunkSender, ChunkView}

  @player_range Valimc.Protocol.EntityTypes.tracking_range("player")

  @doc """
  Track the chunks of the player's current view (VMC-070): its chunk and the
  distance its client requested, clamped to the server's. Leaving chunks the
  client has are forgotten, pending ones dropped; entering ones wait for
  `stream_chunks/1`, nearest first.
  """
  def update_view(state) do
    {center, _} =
      view =
      {World.chunk_key(state.player.x, state.player.z),
       ChunkView.distance(state.requested_view_distance)}

    if view == state.view do
      state
    else
      {entering, leaving} = ChunkView.difference(state.view, view)
      forgotten = Enum.filter(leaving, &MapSet.member?(state.chunks, &1))
      moved = state.view == nil or elem(state.view, 0) != center

      send_packets(
        state,
        if(moved, do: [Packets.center(center)], else: []) ++
          Enum.map(forgotten, &Packets.unload/1)
      )

      regions = regions(view, state.player.dimension)
      World.subscribe(regions, state.regions)
      chunks = MapSet.difference(state.chunks, MapSet.new(forgotten))
      leaving = MapSet.new(leaving)
      {cx, cz} = center

      pending =
        Enum.reject(state.pending, &MapSet.member?(leaving, &1))
        |> Enum.concat(entering)
        |> Enum.sort_by(fn {x, z} -> (x - cx) * (x - cx) + (z - cz) * (z - cz) end)

      send(self(), :send_chunks)

      %{
        state
        | view: view,
          regions: regions,
          chunks: chunks,
          chest_lids: ChestLidReplication.retain(state.chest_lids, chunks),
          pending: pending,
          chunk_sender: ChunkSender.forget(state.chunk_sender, leaving)
      }
      |> want_chunks()
    end
  end

  # The player's tickets (VMC-077e): each region of the view loads its chunks
  # of the view (`:player_loading`, generated nearest to the player first,
  # VMC-075) and ticks those within the simulation distance
  # (`:player_simulation`). Regions are admitted nearest first, as vanilla's
  # player tickets load (VMC-071). An owner told before that is no longer the
  # one of its key (the view left it, it restarted, or the player changed
  # dimension) withdraws. `wanted` remembers which owner was told.
  defp want_chunks(%{view: {{cx, cz} = center, distance} = view} = state) do
    loading = view |> ChunkView.chunks() |> Enum.group_by(&World.region_key/1)
    reach = min(Valimc.config(:simulation_distance), distance)
    size = Valimc.config(:region_size)

    wanted =
      loading
      |> Enum.sort_by(fn {{rx, rz}, _} ->
        (rx * size + div(size, 2) - cx) ** 2 + (rz * size + div(size, 2) - cz) ** 2
      end)
      |> Map.new(fn {key, chunks} ->
        section = World.section(state.player.dimension, key, :section)

        case World.region(section) do
          {:ok, pid} ->
            simulated =
              Enum.filter(chunks, fn {x, z} -> max(abs(x - cx), abs(z - cz)) <= reach end)

            Region.ticket(pid, key, :player_loading, center, chunks)
            Region.ticket(pid, key, :player_simulation, center, simulated)
            {section, pid}

          _ ->
            {section, nil}
        end
      end)

    # A section that moved to another group took the tickets with it
    # (VMC-077j): only sections the view left (or of the dimension the player
    # left) are told to drop them.
    for {section, pid} <- state.wanted, pid != nil, not Map.has_key?(wanted, section) do
      {_, key} = World.split_section(section)
      Region.ticket(pid, key, :player_loading, nil, [])
      Region.ticket(pid, key, :player_simulation, nil, [])
    end

    %{state | wanted: wanted}
  end

  # An owner that restarted since it was told lost the view's wants.
  defp refresh_wants(%{view: {_, _}} = state) do
    current = fn key ->
      case Directory.lookup(key) do
        {pid, _, _} -> pid
        nil -> nil
      end
    end

    if Enum.all?(state.wanted, fn {key, pid} -> pid != nil and current.(key) == pid end),
      do: state,
      else: want_chunks(state)
  end

  defp refresh_wants(state), do: state

  # The sections (routing keys) holding any chunk of the view.
  defp regions({{cx, cz}, distance} = view, dimension) do
    size = Valimc.config(:region_size)
    {rx0, rz0} = World.region_key({cx - distance - 1, cz - distance - 1})
    {rx1, rz1} = World.region_key({cx + distance + 1, cz + distance + 1})

    for rx <- rx0..rx1,
        rz <- rz0..rz1,
        ChunkView.intersects?(
          view,
          {rx * size, rz * size, rx * size + size - 1, rz * size + size - 1}
        ),
        into: MapSet.new(),
        do: {dimension, rx, rz}
  end

  @doc "A 50 ms tick of the chunk stream: refill the send quota, then stream."
  def chunk_tick(state),
    do: stream_chunks(%{state | chunk_sender: ChunkSender.tick(state.chunk_sender)})

  @doc """
  Send the nearest pending chunks the quota allows as one batch; chunks whose
  region is still loading stay pending. A chunk's packet is read from its
  owner's publication, or requested and sent once the reply came (VMC-077e):
  the connection never waits. Nothing streams before the client confirms its
  play teleport.
  """
  def stream_chunks(%{phase: :play, teleport_pending: false, pending: [_ | _]} = state) do
    state = refresh_wants(state)

    case ChunkSender.batch_size(state.chunk_sender) do
      0 ->
        state

      size ->
        # The nearest chunks that are ready, as vanilla sends from loaded ones.
        {ready, sender} =
          state.pending
          |> then(&World.sendable(state.player.dimension, &1, size))
          |> Enum.reduce({[], state.chunk_sender}, fn
            {chunk, {:frame, frame}}, {ready, sender} ->
              {[{chunk, frame} | ready], sender}

            {chunk, {:owner, pid}}, {ready, sender} ->
              case ChunkSender.take(sender, chunk) do
                {:ok, frame, sender} -> {[{chunk, frame} | ready], sender}
                :error -> {ready, ChunkSender.request(sender, chunk, pid)}
              end
          end)

        state = %{state | chunk_sender: sender}
        if ready == [], do: state, else: send_batch(state, Enum.reverse(ready))
    end
  end

  def stream_chunks(state), do: state

  @doc """
  A message that may answer a chunk request: `{:ok, state}` (streaming what is
  now ready) or `:error` when it is not one.
  """
  def chunk_reply(state, message) do
    case ChunkSender.response(state.chunk_sender, message) do
      {:ok, chunk, sender} ->
        sender = if chunk in state.pending, do: sender, else: ChunkSender.forget(sender, [chunk])
        {:ok, stream_chunks(%{state | chunk_sender: sender})}

      :error ->
        :error
    end
  end

  defp send_batch(state, ready) do
    {chunk_frames, lids} =
      Enum.map_reduce(ready, state.chest_lids, fn {chunk, frame}, lids ->
        case World.chest_lid_snapshot(state.player.dimension, chunk) do
          {:ok, owner, positions, lid_frame} ->
            lids = Enum.reduce(positions, lids, &ChestLidReplication.observe(&2, owner, &1, true))
            accepted = Enum.filter(positions, &(lids.positions[&1] == owner))

            lid_frame =
              if accepted == positions,
                do: lid_frame,
                else:
                  Enum.map(accepted, &Packets.frame(Packets.chest_lid(&1, true), state.threshold))

            {[frame, lid_frame], lids}

          :empty ->
            {frame, lids}
        end
      end)

    frames =
      [Packets.frame(Packets.packet("chunk_batch_start", <<>>), state.threshold)] ++
        chunk_frames ++
        [
          Packets.frame(
            Packets.packet("chunk_batch_finished", Wire.varint(length(ready))),
            state.threshold
          )
        ]

    send_frames(state, frames)
    sent = MapSet.new(ready, &elem(&1, 0))

    %{
      state
      | pending: Enum.reject(state.pending, &MapSet.member?(sent, &1)),
        chunks: MapSet.union(state.chunks, sent),
        chest_lids: lids,
        chunk_sender: ChunkSender.sent(state.chunk_sender, length(ready))
    }
  end

  def visible?(state, player),
    do:
      player.pid != self() and not Map.get(player, :won_game, false) and
        Map.get(player, :dimension, :overworld) == Map.get(state.player, :dimension, :overworld) and
        sees?(state, {player.x, player.z}, @player_range)

  @doc """
  Whether the player sees an entity at `{x, z}` whose type vanilla tracks `range`
  chunks away (VMC-070): within `min(range, view distance)` chunks horizontally,
  in a tracked chunk. Vanilla also waits until that chunk was sent; peers here are
  tracked from the join on, items and orbs only in sent chunks (`entity_chunks/2`).
  """
  def sees?(%{view: {_, distance} = view} = state, {x, z}, range) do
    limit = 16 * min(range, distance)
    dx = x - state.player.x
    dz = z - state.player.z
    dx * dx + dz * dz <= limit * limit and ChunkView.contains?(view, World.chunk_key(x, z))
  end

  def sees?(_state, _at, _range), do: false

  @doc "The sent chunks that may hold entities tracked `range` chunks away."
  def entity_chunks(%{view: {_, distance}} = state, range) do
    limit = 16 * min(range, distance)
    %{x: x, z: z} = state.player
    {cx0, cz0} = World.chunk_key(x - limit, z - limit)
    {cx1, cz1} = World.chunk_key(x + limit, z + limit)

    for cx <- cx0..cx1,
        cz <- cz0..cz1,
        MapSet.member?(state.chunks, {cx, cz}),
        square_distance({x, z}, {cx, cz}) <= limit * limit,
        do: {cx, cz}
  end

  def entity_chunks(_state, _range), do: []

  # From `{x, z}` to the nearest point of a chunk, squared.
  defp square_distance({x, z}, {cx, cz}) do
    dx = x - (x |> max(cx * 16) |> min(cx * 16 + 16))
    dz = z - (z |> max(cz * 16) |> min(cz * 16 + 16))
    dx * dx + dz * dz
  end

  # Known peers cost one view lookup when unchanged; see `Players.peer_view/1`.
  def replicate_peer(state, pid) do
    case state.peers[pid] do
      nil ->
        case Players.get(pid) do
          {:ok, player} -> track_peer(state, player, :buffer)
          :error -> state
        end

      known ->
        case Players.peer_view(pid) do
          nil ->
            state

          ^known ->
            if view_visible?(state, known), do: state, else: track_peer_replica(state, pid)

          _changed ->
            track_peer_replica(state, pid)
        end
    end
  end

  def track_peer_replica(state, pid) do
    case Players.peer_replica(pid) do
      nil -> state
      replica -> track_peer(state, replica, :buffer)
    end
  end

  def view_visible?(state, view),
    do: sees?(state, {elem(view, 2) / 4096, elem(view, 4) / 4096}, @player_range)

  def track_peer(state, player, mode \\ :direct) do
    cond do
      player.pid == self() or not Process.alive?(player.pid) ->
        state

      visible?(state, player) ->
        view = Packets.view(player)

        packets =
          case state.peers[player.pid] do
            nil ->
              body =
                if player.living.health.value <= 0 and player.living.health.death_ticks >= 20,
                  do: [],
                  else:
                    [
                      Packets.add_entity(player),
                      Packets.player_flags(player),
                      Packets.player_pose(player),
                      Packets.player_environment(player),
                      Packets.player_use(player),
                      Packets.player_health(player),
                      Packets.player_absorption(player),
                      Packets.attribute(
                        player.entity_id,
                        elem(Valimc.Living.Attributes.absorption(player.living.effects), 1).attribute
                      )
                    ] ++ Packets.player_equipment(player)

              [Packets.player_info(player) | body]

            ^view ->
              []

            previous ->
              List.wrap(Packets.move_entity(player, previous))
          end

        if packets == [] do
          state
        else
          state = emit_peer_packets(state, packets, mode)
          %{state | peers: Map.put(state.peers, player.pid, view)}
        end

      Map.has_key?(state.peers, player.pid) ->
        state =
          emit_peer_packets(
            state,
            [Packets.remove_entity(player), Packets.remove_info(player)],
            mode
          )

        %{state | peers: Map.delete(state.peers, player.pid)}

      true ->
        state
    end
  end

  def emit_peer_packets(state, packets, :direct) do
    send_packets(state, packets)
    state
  end

  def emit_peer_packets(state, packets, :buffer),
    do: %{state | outbound: [packets | state.outbound]}
end
