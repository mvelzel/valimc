defmodule Valimc.Session.Events do
  @moduledoc """
  World and peer events (VMC-069). Since VMC-077i3 an event has two parts:
  what the client sees (`view/2`, at the connection: block updates of loaded
  chunks, entity pickups, peer packets, lids, chat) and what the session does
  (`session/2`, at the owner: block menus' grants and contents, and block
  changes that touch mining, menus and the pose).
  """

  alias Valimc.Data.Grid

  alias Valimc.Protocol.{
    Packets
  }

  alias Valimc.Player.Menus
  alias Valimc.Player.Mining

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, send_frames: 2]

  alias Valimc.World

  alias Valimc.World.{ChestLidReplication}

  @doc "The session's part of `event`."
  def session(
        %{
          phase: :play,
          table_menu: %{kind: kind, owner: owner, view_ref: ref, position: position}
        } = state,
        {:container_changed, owner, ref, position, revision}
      )
      when kind in [:chest, :cooking] and is_integer(revision),
      do: Menus.changed(state, revision)

  def session(
        %{
          phase: :play,
          table_menu: %{kind: :cooking, owner: owner, view_ref: ref, position: position}
        } = state,
        {:container_progress, owner, ref, position, generation}
      )
      when is_integer(generation) and generation > 0,
      do: Menus.progressed(state, generation)

  def session(
        %{phase: :play, table_menu: %{kind: kind, owner: owner, view_ref: ref}} = state,
        {:container_closed, owner, ref}
      )
      when kind in [:chest, :cooking],
      do: Menus.close(state)

  # Blocks changed near the player: its pose is sampled again, and mining and
  # an open block menu check their block.
  def session(%{phase: :play} = state, event)
      when is_tuple(event) and elem(event, 0) in [:block, :block_batch] do
    state
    |> Map.put(:pose_generation, state.pose_generation + 1)
    |> Mining.mining_changed()
    |> Menus.check_table_menu()
  end

  def session(state, _), do: state

  def view(
        %{phase: :play} = state,
        {:chest_lid, owner, {x, _, z} = position, open, frame, sound}
      ) do
    chunk = Grid.chunk_key(x, z)

    if MapSet.member?(state.chunks, chunk) and
         World.existing_owner(Grid.section(state.player.dimension, chunk)) ==
           {:ok, owner} do
      lids = ChestLidReplication.observe(state.chest_lids, owner, position, open)

      sounds =
        if sound != nil and Valimc.Protocol.ChestSounds.audible?(state.player, position),
          do: [sound],
          else: []

      frames =
        if not open or lids.positions[position] == owner, do: [frame | sounds], else: sounds

      send_frames(state, frames)
      %{state | chest_lids: lids}
    else
      state
    end
  end

  # `Level.globalLevelEvent` (an end portal opening, VMC-026b3): every player hears it.
  def view(%{phase: :play} = state, {:global_level_event, type, position, data}) do
    send_packets(state, [Packets.level_event(type, position, data, true)])
    state
  end

  def view(%{phase: :play} = state, {:chat, message}) do
    send_packets(state, [Packets.chat(message)])
    state
  end

  def view(%{phase: :play} = state, {:kick, reason}),
    do: Valimc.Protocol.Codec.reject(state, reason)

  def view(%{phase: :play} = state, {:packet, packet}) do
    send_packets(state, [packet])
    state
  end

  def view(%{phase: :play} = state, :spawn_position) do
    send_packets(state, [Valimc.Player.Packets.spawn_position()])
    state
  end

  def view(%{phase: :play} = state, {:block, {x, _, z} = pos, block}) do
    if MapSet.member?(state.chunks, Grid.chunk_key(x, z)),
      do: send_packets(state, [Packets.block(pos, block)])

    state
  end

  # `/fillbiome` (VMC-053j4): the new biomes of chunks this player has loaded.
  # A packet not sent yet that a reply brought is stale after a change of its
  # chunk; it is asked for again (VMC-077e).
  def view(%{phase: :play} = state, {:chunks_biomes, entries}) do
    state = forget_ready(state, Enum.map(entries, &elem(&1, 0)))

    entries =
      for {chunk, bytes} <- entries, MapSet.member?(state.chunks, chunk), do: {chunk, bytes}

    if entries != [], do: send_packets(state, [Packets.chunks_biomes(entries)])
    state
  end

  def view(%{phase: :play} = state, {:block_batch, updates}) do
    state = forget_ready(state, Enum.map(updates, &chunk_of(elem(&1, 0))))
    frames = for {target, frame} <- updates, sends?(state.chunks, target), do: frame
    send_frames(state, frames)
    state
  end

  # Vanilla broadcasts level events to players within 64 blocks of the block corner.
  def view(%{phase: :play, player: %{x: px, y: py, z: pz}} = state, {:level_events, events}) do
    packets =
      for {{x, y, z} = position, type, data} <- events,
          MapSet.member?(state.chunks, Grid.chunk_key(x, z)),
          (x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz) < 4096.0,
          do: Packets.level_event(type, position, data)

    if packets != [], do: send_packets(state, packets)
    state
  end

  # A sound at a position (VMC-050a): to players within its range of it.
  def view(
        %{phase: :play, player: %{x: px, y: py, z: pz}} = state,
        {:sound, {x, y, z}, range, packet}
      ) do
    if MapSet.member?(state.chunks, Grid.chunk_key(floor(x), floor(z))) and
         (x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz) < range * range,
       do: send_packets(state, [packet])

    state
  end

  # The tab list holds every online player, near or far; players themselves
  # come and go with the rows their groups publish (VMC-077i4).
  def view(%{phase: :play} = state, {:player_joined, player}) do
    if player.pid != state.connection,
      do: send_packets(state, [Valimc.Player.Packets.player_info(player)])

    state
  end

  def view(%{phase: :play} = state, {:player_info, packet}) do
    send_packets(state, [packet])
    state
  end

  def view(%{phase: :play} = state, {:experience_pickup, epoch, id, collector}) do
    if match?(%{epoch: ^epoch}, state.entity_replication.tracked[id]),
      do: send_packets(state, [Valimc.Protocol.EntityPackets.pickup(id, collector, 1)])

    state
  end

  def view(%{phase: :play} = state, {:item_pickup, epoch, id, collector, count}) do
    if match?(%{epoch: ^epoch}, state.entity_replication.tracked[id]),
      do: send_packets(state, [Valimc.Protocol.EntityPackets.pickup(id, collector, count)])

    state
  end

  # A player's own event (a swing, a hurt, a death): for observers tracking it.
  def view(%{phase: :play} = state, {:player_packet, _pid, entity, packet, {threshold, frame}}) do
    if Map.has_key?(state.entity_replication.tracked, entity) do
      if threshold == state.threshold,
        do: send_frames(state, [frame]),
        else: send_packets(state, [packet])
    end

    state
  end

  # A respawned player is a new body: it spawns again from its row.
  def view(%{phase: :play} = state, {:player_respawned, _pid, entity}) do
    untrack(state, entity)
  end

  def view(%{phase: :play} = state, {:player_left, player}) do
    state = untrack(state, player.entity_id)
    send_packets(state, [Packets.remove_info(player)])
    state
  end

  @doc "The client's part of `event`."
  def view(state, _), do: state

  defp untrack(state, entity) do
    if Map.has_key?(state.entity_replication.tracked, entity) do
      send_packets(state, [Valimc.Protocol.EntityPackets.remove([entity])])

      %{
        state
        | entity_replication: Valimc.Entity.Observer.untrack(state.entity_replication, entity)
      }
    else
      state
    end
  end

  defp forget_ready(state, chunks),
    do: %{state | chunk_sender: Valimc.Session.ChunkSender.forget(state.chunk_sender, chunks)}

  # Light after block changes reaches a client only for a chunk on the edge of
  # what it has, as vanilla sends it (`ChunkMap.isChunkOnTrackedBorder`):
  # inside it the client relights from the block updates itself (VMC-077c).
  defp sends?(chunks, {:light, {cx, cz} = chunk}) do
    MapSet.member?(chunks, chunk) and
      Enum.any?(
        for(dx <- -1..1, dz <- -1..1, {dx, dz} != {0, 0}, do: {cx + dx, cz + dz}),
        &(not MapSet.member?(chunks, &1))
      )
  end

  defp sends?(chunks, chunk), do: MapSet.member?(chunks, chunk)

  defp chunk_of({:light, chunk}), do: chunk
  defp chunk_of(chunk), do: chunk
end
