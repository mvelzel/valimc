defmodule Valimc.Player.Movement do
  require Logger

  @moduledoc """
  Player movement in the player's session: input, position and motion
  validation, pose sampling, kinetics and movement attributes (VMC-069).
  A move packet is validated synchronously against published snapshots by
  the physics kernel (VMC-077l): accepted, or corrected by a teleport.
  """

  alias Valimc.Protocol.{ClientTick, Packets}
  alias Valimc.Living.Attributes
  import Bitwise, only: [&&&: 2]

  import Valimc.Protocol.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.Data.Metrics
  alias Valimc.Player.{PlayerList, Input, Motion, MotionQuery, PoseQuery}

  def update_player_input(state, input) do
    if input == state.player.input do
      state
    else
      player = %{state.player | input: input}
      PlayerList.update(state.connection, player)
      publish_movement_speed(%{state | player: player})
    end
  end

  @doc false
  def publish_movement_speed(state) do
    effects = state.player.living.effects
    sprint = Attributes.sprinting?(state.player.input.shared_flags)
    signature = Attributes.movement_signature(effects, sprint)

    if signature == state.movement_speed_view do
      state
    else
      {:ok, derived} = Attributes.movement_speed(effects, sprint)
      send_packets(state, [Packets.attribute(state.player.entity_id, derived.attribute)])
      %{state | movement_speed_view: signature}
    end
  end

  @doc false
  def publish_jump_boost(state) do
    level = Attributes.jump_boost_level(state.player.living.effects)

    if level == state.jump_boost_view do
      state
    else
      {:ok, derived} = Attributes.jump_boost(state.player.living.effects)
      send_packets(state, [Packets.attribute(state.player.entity_id, derived.attribute)])
      %{state | jump_boost_view: level}
    end
  end

  @doc false
  def publish_absorption(state) do
    living = state.player.living
    view = {Attributes.absorption_level(living.effects), living.absorption}

    if view == state.absorption_view do
      state
    else
      previous = state.absorption_view
      {:ok, derived} = Attributes.absorption(living.effects)

      packets =
        if previous == nil or elem(previous, 0) != elem(view, 0),
          do: [Packets.attribute(state.player.entity_id, derived.attribute)],
          else: []

      packets =
        if previous == nil or elem(previous, 1) != elem(view, 1),
          do: packets ++ [Valimc.Player.Packets.player_absorption(state.player)],
          else: packets

      PlayerList.update(state.connection, state.player)
      send_packets(state, packets)
      %{state | absorption_view: view}
    end
  end

  def admit_position(state) do
    case ClientTick.position(state.client_tick) do
      {:ok, frame} -> %{state | client_tick: frame}
      {:error, :duplicate_position} -> reject(state, "Invalid player movement")
    end
  end

  def move(%{teleport_pending: true} = state, _, _), do: state

  def move(state, changes, flags) do
    player = Map.merge(state.player, changes)

    if not Valimc.Player.State.valid_pose?(player),
      do: reject(state, "Position outside world bounds")

    state = count_motion_packet(state)
    rotation = Map.take(changes, [:yaw, :pitch])
    rotated = Map.merge(state.player, rotation)
    PlayerList.update(state.connection, rotated)
    state = %{state | player: rotated}

    if Map.has_key?(changes, :x) or ((flags &&& 1) != 0 and Motion.distance(player) > 0) do
      %{first: first, packets: count} = state.motion_window
      position = Map.take(player, [:x, :y, :z])

      distance =
        Enum.sum(
          for axis <- [:x, :y, :z],
              do: :math.pow(Map.fetch!(position, axis) - Map.fetch!(first, axis), 2)
        )

      allowance = 100.0 * if(count > 5, do: 1, else: count)

      {vx, vy, vz} = state.player.motion.velocity

      cond do
        # "moved too quickly"
        distance - (vx * vx + vy * vy + vz * vz) > allowance ->
          Logger.info(
            "movement correction: too quickly, distance² #{Float.round(distance, 2)}, " <>
              "allowance #{allowance}, packets #{count}, mode #{state.player.game_mode.current}"
          )

          correct_motion(state, :movement_speed_corrections)

        state.life_stage != :alive ->
          state

        true ->
          validate(state, position, flags)
      end
    else
      motion =
        Motion.accept(state.player.motion, {0.0, 0.0, 0.0}, flags, player.abilities.flying)

      player = %{state.player | motion: motion}
      PlayerList.update(state.connection, player)
      %{state | player: player}
    end
  end

  # Vanilla measures "moved too quickly" from the position at the start of the
  # server tick over the move packets since then. Here the window is the
  # client's own tick (it ends with `client_tick_end` and holds at most one
  # position), so a server that applies several ticks' packets together never
  # reads them as one fast move.
  def count_motion_packet(state) do
    window =
      case state.motion_window do
        %{} = window -> %{window | packets: window.packets + 1}
        nil -> %{packets: 1, first: Map.take(state.player, [:x, :y, :z])}
      end

    %{state | motion_window: window}
  end

  # Vanilla's rules (`handleMovePlayer`): a move into a new collision is
  # corrected, and so is one that "moved wrongly" from a clear box; a move the
  # kernel cannot read (chunks not loaded) is corrected too.
  defp validate(state, position, flags) do
    case MotionQuery.run(state.player, position, flags) do
      {:ok, %{accepted: true} = result} ->
        Metrics.add(:movement_validations)
        accept(state, position, result)

      {:ok, %{accepted: false}} ->
        Logger.info(
          "movement correction: collision, mode #{state.player.game_mode.current}, " <>
            "to #{inspect(position)}"
        )

        correct_motion(state, :movement_collision_corrections)

      {:error, reason} ->
        Logger.info(
          "movement correction: geometry #{inspect(reason)}, " <>
            "mode #{state.player.game_mode.current}, to #{inspect(position)}"
        )

        correct_motion(state, :movement_geometry_corrections)
    end
  end

  defp accept(state, position, result) do
    # The kernel accepted the packet's movement and flags into the motion.
    player =
      state.player
      |> Map.merge(position)
      |> Map.put(:pose, result.pose)
      |> Map.put(:motion, result.motion)

    if result.pose != state.player.pose,
      do: send_packets(state, [Valimc.Player.Packets.player_pose(player)])

    next =
      %{state | player: player, pose_checked: nil}
      |> Valimc.Player.Vitals.apply_movement_exhaustion(result.exhaustion)
      |> apply_kinetic_tick(
        result.ticked,
        result.kinetics.tick.bounced,
        result.kinetics.packet.bounced
      )
      |> Valimc.Player.Vitals.observe_environment(
        result.powder_snow,
        result.submerged,
        result.eye_water,
        result.kinetics.tick
      )
      |> monitor_pose_sources(result.sources)
      |> Valimc.Player.Vitals.apply_landing(result.landing)

    if next.life_stage == :alive, do: %{next | pose_checked: pose_signature(next)}, else: next
  end

  def correct_motion(state, metric) do
    Metrics.add(metric)
    player = %{state.player | motion: Motion.corrected(state.player.motion)}
    relocate(state, player, false)
  end

  @doc false
  # Move the player to `player`'s pose with a teleport the client confirms;
  # `delta` is the movement the packet hands the client (a portal keeps the
  # entering velocity, VMC-026b).
  def relocate(state, player, reset_motion \\ true, delta \\ {0.0, 0.0, 0.0}) do
    state = Valimc.Player.Mining.cancel_mining(state)
    state = Valimc.Player.Menus.close(state)
    player = if reset_motion, do: %{player | motion: %Motion{}}, else: player

    teleport = if state.teleport == 2_147_483_647, do: 0, else: state.teleport + 1

    Logger.debug(fn ->
      {:current_stacktrace, [_, _ | frames]} = Process.info(self(), :current_stacktrace)

      callers =
        frames |> Enum.take(3) |> Enum.map_join(" < ", &Exception.format_stacktrace_entry/1)

      "teleport #{teleport} to #{inspect({player.x, player.y, player.z})} from #{callers}"
    end)

    send_packets(state, [Packets.teleport(player, teleport, delta)])
    PlayerList.update(state.connection, player)

    # The connection's view follows the new pose (`Valimc.Net.Link`).
    %{
      state
      | player: player,
        # A teleport is no movement through portals (VMC-026c): contact starts anew.
        portal: Map.get(state, :portal) && %{state.portal | last: nil},
        teleport: teleport,
        teleport_pending: true,
        login_velocity_pending: false,
        motion_window: nil,
        pose_checked: nil,
        pose_generation: state.pose_generation + 1
    }
  end

  def pose_signature(state),
    do: {PoseQuery.signature(state.player), state.pose_generation}

  @doc """
  The pose, fluid, powder snow and kinetics of a resting or ticking player,
  sampled synchronously when its signature changed or a simulation is due
  and it is in an environment that keeps acting on it.
  """
  def sample_pose(%{life_stage: :alive, teleport_pending: false} = state) do
    signature = pose_signature(state)

    active =
      state.simulation_due and
        (Valimc.Living.environment_active?(state.player.living) or state.fire_damage_due or
           state.fire_contacts_active or not state.player.motion.settled)

    if Input.loaded?(state.player.input) and (signature != state.pose_checked or active) do
      case PoseQuery.run(state.player) do
        {:ok, result} -> apply_pose(state, result)
        {:error, _} -> state
      end
    else
      state
    end
  end

  def sample_pose(state), do: state

  defp apply_pose(state, result) do
    player = %{
      state.player
      | pose: result.pose,
        motion: %{state.player.motion | swimming: result.swimming}
    }

    if result.pose != state.player.pose,
      do: send_packets(state, [Valimc.Player.Packets.player_pose(player)])

    state =
      %{state | player: player}
      |> apply_kinetic_tick(result.ticked, result.kinetics.bounced, false)
      |> Valimc.Player.Vitals.observe_environment(
        result.powder_snow,
        result.submerged,
        result.eye_water,
        result.kinetics
      )
      |> monitor_pose_sources(result.sources)

    if state.life_stage == :alive,
      do: %{state | pose_checked: pose_signature(state)},
      else: state
  end

  # The motion after the server's tick replaces the player's when a tick is
  # due; otherwise only the packet's restitution counts.
  def apply_kinetic_tick(state, ticked, tick_bounced, packet_bounce) do
    {player, bounced} =
      if state.simulation_due do
        Metrics.add(:player_physics_ticks)
        {%{state.player | motion: ticked}, packet_bounce or tick_bounced}
      else
        {state.player, packet_bounce}
      end

    state = %{state | player: player}
    # Native restitution marks syncPosition, not syncVelocity. The controlling
    # client already simulates contact; a forecast impulse here bounces it before
    # reaching the block and can suppress the actual landing packet/damage.
    if bounced do
      packet = Valimc.Protocol.EntityPackets.motion(player.entity_id, player.motion.velocity)
      broadcast_player_packet(state, packet)
    else
      state
    end
  end

  def send_velocity(state, velocity) do
    packet = Valimc.Protocol.EntityPackets.motion(state.player.entity_id, velocity)
    send_packets(state, [packet])

    broadcast_player_packet(state, packet)
  end

  # Frame (and compress) once; peers share the refc binary and only encrypt it.
  @doc false
  def broadcast_player_packet(state, packet) do
    framed = {state.threshold, IO.iodata_to_binary(Packets.frame(packet, state.threshold))}

    for pid <- PlayerList.around(state.player),
        pid != state.connection,
        do:
          Valimc.Player.PlayerList.deliver(
            pid,
            {:player_packet, state.connection, state.player.entity_id, packet, framed}
          )

    state
  end

  def monitor_pose_sources(state, sources) do
    owners = MapSet.new(sources)

    retained =
      Map.filter(state.pose_sources, fn {ref, owner} ->
        if MapSet.member?(owners, owner) do
          true
        else
          Process.demonitor(ref, [:flush])
          false
        end
      end)

    existing = MapSet.new(Map.values(retained))

    sources =
      Enum.reduce(MapSet.difference(owners, existing), retained, fn {pid, _} = owner, acc ->
        Map.put(acc, Process.monitor(pid), owner)
      end)

    %{state | pose_sources: sources}
  end
end
