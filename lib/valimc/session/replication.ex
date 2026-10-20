defmodule Valimc.Session.Replication do
  @moduledoc "What a connection's client sees: view distance, chunk streaming and peer player replication (VMC-069)."

  alias Valimc.Protocol.{
    Packets,
    Wire
  }

  import Valimc.Net.Codec,
    only: [send_packets: 2, send_frames: 2]

  alias Valimc.{
    Players,
    PlayerAbsorption,
    World
  }

  alias Valimc.World.{ChestLidReplication}

  @doc false
  def update_view(state) do
    center = World.chunk_key(state.player.x, state.player.z)

    if center == state.center do
      state
    else
      {cx, cz} = center
      d = Valimc.config(:view_distance)
      desired = MapSet.new(for x <- (cx - d)..(cx + d), z <- (cz - d)..(cz + d), do: {x, z})

      send_packets(
        state,
        [Packets.center(center)] ++
          Enum.map(MapSet.difference(state.chunks, desired), &Packets.unload/1)
      )

      regions = MapSet.new(desired, &World.region_key/1)
      World.subscribe(regions, state.regions)

      pending =
        MapSet.difference(desired, state.chunks)
        |> Enum.sort_by(fn {x, z} -> abs(x - cx) + abs(z - cz) end)

      send(self(), :send_chunks)

      state = %{
        state
        | center: center,
          regions: regions,
          chunks: MapSet.intersection(state.chunks, desired),
          chest_lids: ChestLidReplication.retain(state.chest_lids, desired),
          pending: pending
      }

      state
    end
  end

  def stream_chunks(
        %{phase: :play, teleport_pending: false, batch_pending: false, pending: [_ | _]} = state
      ) do
    {batch, pending} = Enum.split(state.pending, 4)

    {chunk_frames, lids} =
      Enum.map_reduce(batch, state.chest_lids, fn chunk, lids ->
        frame = World.chunk(chunk)

        case World.chest_lid_snapshot(chunk) do
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
            Packets.packet("chunk_batch_finished", Wire.varint(length(batch))),
            state.threshold
          )
        ]

    send_frames(state, frames)

    %{
      state
      | pending: pending,
        chunks: Enum.reduce(batch, state.chunks, &MapSet.put(&2, &1)),
        chest_lids: lids,
        batch_pending: true
    }
  end

  def stream_chunks(state), do: state

  def visible?(state, player) do
    {cx, cz} = World.chunk_key(state.player.x, state.player.z)
    {px, pz} = World.chunk_key(player.x, player.z)
    d = Valimc.config(:view_distance)
    player.pid != self() and abs(cx - px) <= d and abs(cz - pz) <= d
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

  def view_visible?(state, view) do
    {cx, cz} = World.chunk_key(state.player.x, state.player.z)
    {px, pz} = World.chunk_key(elem(view, 2) / 4096, elem(view, 4) / 4096)
    d = Valimc.config(:view_distance)
    abs(cx - px) <= d and abs(cz - pz) <= d
  end

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
                if player.health.value <= 0 and player.health.death_ticks >= 20,
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
                      Packets.absorption_attributes(
                        player,
                        elem(PlayerAbsorption.derive(player.effects), 1).attribute
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
