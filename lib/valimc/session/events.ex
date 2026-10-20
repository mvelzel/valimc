defmodule Valimc.Session.Events do
  @moduledoc "World and peer events delivered to a connection's client (block updates, entity pickups, peer packets, lids, weather) (VMC-069)."

  alias Valimc.Protocol.{
    Packets
  }

  alias Valimc.Player.Placement
  alias Valimc.Player.Menus
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Mining
  alias Valimc.Session.Replication

  import Valimc.Net.Codec,
    only: [send_packets: 2, send_frames: 2]

  alias Valimc.{
    Players,
    PlayerInput,
    World
  }

  alias Valimc.World.{ChestLidReplication}

  @doc false
  def event(
        %{phase: :play, table_job: %{ref: ref, owner: owner} = job} = state,
        {:table_admitted, ref, owner, decision}
      ) do
    state = Menus.cancel_table_query(state)

    current =
      System.monotonic_time(:millisecond) < job.grant.expires and
        if(job.kind == :open,
          do: state.player.game_mode.current == job.grant.mode,
          else: Menus.menu_signature(state) == job.signature
        ) and
        World.existing_owner(job.key) == {:ok, owner}

    case {job.kind, decision, current} do
      {:open, :open, true} ->
        if state.life_stage == :alive and not state.teleport_pending and
             PlayerInput.loaded?(state.player.input) and Mining.reachable?(state, job.position),
           do: Menus.open_table_menu(state, job.position, owner, job.command.sequence),
           else: Menus.acknowledge_table_use(state, job.command)

      {:open, :pass, true} ->
        Placement.execute_placement(state, job.command, job.placement)

      {:open, {kind, block, view}, true} when kind in [:chest, :cooking] ->
        if state.life_stage == :alive and not state.teleport_pending and
             PlayerInput.loaded?(state.player.input) and Mining.reachable?(state, job.position),
           do:
             Menus.open_container_menu(
               state,
               kind,
               job.position,
               owner,
               block,
               view,
               job.command.sequence
             ),
           else: Menus.acknowledge_table_use(state, job.command)

      {:open, _, _} ->
        Menus.acknowledge_table_use(state, job.command)

      {_, :valid, true} ->
        if Menus.table_player_valid?(state) do
          state =
            if job.kind == :click, do: Menus.apply_menu_click(state, job.command), else: state

          Menus.drain_table_clicks(state)
        else
          Menus.begin_table_close(state)
        end

      {operation, {kind, block, view}, true}
      when operation in [:subscribe, :check, :refresh, :progress, :click] and
             kind in [:chest, :cooking] ->
        if state.table_menu.kind == kind and Menus.table_player_valid?(state) do
          properties_only =
            operation == :progress and kind == :cooking and
              state.table_menu.view.revision == view.revision and
              state.table_menu.view.cooking.slots == view.cooking.slots

          state = %{
            state
            | table_menu: %{
                state.table_menu
                | block: block,
                  view: view,
                  dirty: false,
                  progress_dirty: false,
                  subscribed: true
              }
          }

          state =
            cond do
              operation == :click ->
                Menus.apply_menu_click(state, job.command)

              properties_only ->
                send_packets(state, Packets.cooking_properties(state.table_menu.id, view.cooking))
                state

              true ->
                CreativeInventory.resync_inventory(state)
            end

          Menus.drain_table_clicks(state)
        else
          Menus.begin_table_close(state)
        end

      _ ->
        Menus.begin_table_close(state)
    end
  end

  def event(
        %{
          phase: :play,
          table_menu: %{kind: kind, owner: owner, view_ref: ref, position: position} = menu
        } = state,
        {:container_changed, owner, ref, position, revision}
      )
      when kind in [:chest, :cooking] do
    if revision > menu.view.revision do
      Menus.check_table_menu(%{state | table_menu: %{menu | dirty: true}})
    else
      state
    end
  end

  def event(
        %{
          phase: :play,
          table_menu: %{kind: :cooking, owner: owner, view_ref: ref, position: position} = menu
        } = state,
        {:container_progress, owner, ref, position, generation}
      )
      when is_integer(generation) and generation > 0 do
    if generation > Map.get(menu.view, :generation, 0),
      do: Menus.check_table_menu(%{state | table_menu: %{menu | progress_dirty: true}}),
      else: state
  end

  def event(
        %{phase: :play, table_menu: %{kind: kind, owner: owner, view_ref: ref}} = state,
        {:container_closed, owner, ref}
      )
      when kind in [:chest, :cooking],
      do: Menus.begin_table_close(state)

  def event(
        %{phase: :play} = state,
        {:chest_lid, owner, {x, _, z} = position, open, frame, sound}
      ) do
    chunk = World.chunk_key(x, z)

    if MapSet.member?(state.chunks, chunk) and
         World.existing_owner(World.region_key(chunk)) == {:ok, owner} do
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

  def event(%{phase: :play} = state, {:chat, message}) do
    send_packets(state, [Packets.chat(message)])
    state
  end

  def event(%{phase: :play} = state, {:packet, packet}) do
    send_packets(state, [packet])
    state
  end

  def event(%{phase: :play} = state, :spawn_position) do
    send_packets(state, [Packets.spawn_position()])
    state
  end

  def event(%{phase: :play} = state, {:block, {x, _, z} = pos, block}) do
    if MapSet.member?(state.chunks, World.chunk_key(x, z)),
      do: send_packets(state, [Packets.block(pos, block)])

    state
    |> Map.put(:pose_generation, state.pose_generation + 1)
    |> Mining.mining_changed()
    |> Menus.check_table_menu()
  end

  def event(%{phase: :play} = state, {:block_batch, updates}) do
    frames = for {chunk, frame} <- updates, MapSet.member?(state.chunks, chunk), do: frame
    send_frames(state, frames)

    state
    |> Map.put(:pose_generation, state.pose_generation + 1)
    |> Mining.mining_changed()
    |> Menus.check_table_menu()
  end

  # Vanilla broadcasts level events to players within 64 blocks of the block corner.
  def event(%{phase: :play, player: %{x: px, y: py, z: pz}} = state, {:level_events, events}) do
    packets =
      for {{x, y, z} = position, type, data} <- events,
          MapSet.member?(state.chunks, World.chunk_key(x, z)),
          (x - px) * (x - px) + (y - py) * (y - py) + (z - pz) * (z - pz) < 4096.0,
          do: Packets.level_event(type, position, data)

    if packets != [], do: send_packets(state, packets)
    state
  end

  def event(%{phase: :play} = state, {:player_joined, player}),
    do: Replication.track_peer(state, player)

  def event(%{phase: :play} = state, {:experience_pickup, epoch, id, collector}) do
    if match?({^epoch, _}, state.entity_replication.tracked[id]),
      do: send_packets(state, [Valimc.Protocol.EntityPackets.pickup(id, collector, 1)])

    state
  end

  def event(%{phase: :play} = state, {:item_pickup, epoch, id, collector, count}) do
    if match?({^epoch, _}, state.entity_replication.tracked[id]),
      do: send_packets(state, [Valimc.Protocol.EntityPackets.pickup(id, collector, count)])

    state
  end

  def event(%{phase: :play} = state, {:player_packet, pid, entity, packet, {threshold, frame}}) do
    case Map.get(state.peers, pid) do
      view when is_tuple(view) and elem(view, 0) == entity ->
        if threshold == state.threshold,
          do: send_frames(state, [frame]),
          else: send_packets(state, [packet])

      _ ->
        :ok
    end

    state
  end

  def event(%{phase: :play} = state, {:player_packet, pid, entity, packet}) do
    case Map.get(state.peers, pid) do
      view when is_tuple(view) and elem(view, 0) == entity -> send_packets(state, [packet])
      _ -> :ok
    end

    state
  end

  def event(%{phase: :play} = state, {:player_use_packet, pid, entity, packet}) do
    case {Map.get(state.peers, pid), Players.get(pid)} do
      {view, {:ok, %{entity_id: ^entity} = player}} when is_tuple(view) ->
        # Native use starts by refreshing equipment. Sample the current owner
        # publication before sending the animation flag, within this peer view.
        state = Replication.track_peer(state, player)
        event(state, {:player_packet, pid, entity, packet})

      _ ->
        state
    end
  end

  def event(%{phase: :play} = state, {:player_respawned, pid, entity}) do
    case Players.get(pid) do
      {:ok, %{entity_id: ^entity} = player} ->
        if Map.has_key?(state.peers, pid),
          do: send_packets(state, [Packets.remove_entity(player)])

        Replication.track_peer(%{state | peers: Map.delete(state.peers, pid)}, player)

      _ ->
        state
    end
  end

  def event(%{phase: :play} = state, {:player_left, player}) do
    if Map.has_key?(state.peers, player.pid),
      do: send_packets(state, [Packets.remove_entity(player), Packets.remove_info(player)])

    %{state | peers: Map.delete(state.peers, player.pid)}
  end

  def event(state, _), do: state
end
