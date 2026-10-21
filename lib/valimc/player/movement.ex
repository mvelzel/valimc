defmodule Valimc.Player.Movement do
  @moduledoc "Player movement inside the connection: input, position and motion admission, pose jobs, kinetics and movement attributes (VMC-069)."

  alias Valimc.Protocol.{
    ClientTick,
    EffectTypes,
    Packets
  }

  alias Valimc.Session.Jobs

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    Metrics,
    Players,
    PlayerAbsorption,
    PlayerMovementSpeed,
    PlayerEnvironment,
    PlayerInput,
    PlayerKinetics,
    PlayerMotion,
    PlayerMotionQuery,
    PlayerPoseQuery,
    PlayerStore
  }

  import Bitwise
  @absorption EffectTypes.id("absorption")

  def update_player_input(state, input) do
    if input == state.player.input do
      state
    else
      player = %{state.player | input: input}
      Players.update(self(), player)
      publish_movement_speed(%{state | player: player})
    end
  end

  @doc false
  def publish_movement_speed(state) do
    {_, sprint} = signature = PlayerMovementSpeed.signature(state.player)

    if signature == state.movement_speed_view do
      state
    else
      {:ok, derived} = PlayerMovementSpeed.derive(state.player.effects, sprint)
      send_packets(state, [Packets.movement_attributes(state.player, derived.attribute)])
      %{state | movement_speed_view: signature}
    end
  end

  @doc false
  def publish_jump_boost(state) do
    level = Valimc.PlayerJumpBoost.level(state.player.effects)

    if level == state.jump_boost_view do
      state
    else
      {:ok, derived} = Valimc.PlayerJumpBoost.derive(state.player.effects)
      send_packets(state, [Packets.jump_attributes(state.player, derived.attribute)])
      %{state | jump_boost_view: level}
    end
  end

  @doc false
  def absorption_level(effects) do
    case effects[@absorption] do
      nil -> nil
      [{_, amp, _, _, _} | _] -> amp
    end
  end

  @doc false
  def publish_absorption(state) do
    view = {absorption_level(state.player.effects), state.player.absorption}

    if view == state.absorption_view do
      state
    else
      previous = state.absorption_view
      {:ok, derived} = PlayerAbsorption.derive(state.player.effects)

      packets =
        if previous == nil or elem(previous, 0) != elem(view, 0),
          do: [Packets.absorption_attributes(state.player, derived.attribute)],
          else: []

      packets =
        if previous == nil or elem(previous, 1) != elem(view, 1),
          do: packets ++ [Packets.player_absorption(state.player)],
          else: packets

      Players.update(self(), state.player)
      send_packets(state, packets)
      Enum.each(packets, &broadcast_player_packet(state, &1))
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
    if not PlayerStore.valid_pose?(player), do: reject(state, "Position outside world bounds")
    state = count_motion_packet(state)
    rotation = Map.take(changes, [:yaw, :pitch])
    rotated = Map.merge(state.player, rotation)
    Players.update(self(), rotated)
    state = %{state | player: rotated}

    if Map.has_key?(changes, :x) or ((flags &&& 1) != 0 and PlayerMotion.distance(player) > 0) do
      %{first: first, packets: count} = state.motion_window
      position = Map.take(player, [:x, :y, :z])

      distance =
        Enum.sum(
          for axis <- [:x, :y, :z],
              do: :math.pow(Map.fetch!(position, axis) - Map.fetch!(first, axis), 2)
        )

      allowance = 100.0 * if(count > 5, do: 1, else: count)

      {vx, vy, vz} = state.player.motion.velocity

      if distance - (vx * vx + vy * vy + vz * vz) > allowance do
        correct_motion(state, :movement_speed_corrections)
      else
        input = %{
          position: position,
          flags: flags,
          # The admission window bounds the owner round trip (scaled in tests, VMC-073).
          deadline:
            System.monotonic_time(:millisecond) +
              Valimc.Txn.Permits.window(250, state.player.uuid),
          token: make_ref(),
          retry: nil,
          prepared: nil
        }

        state
        |> cancel_pose_job()
        |> Map.put(:motion_pending, input)
        |> start_motion()
      end
    else
      motion =
        PlayerMotion.accept(state.player.motion, {0.0, 0.0, 0.0}, flags, player.abilities.flying)

      player = %{state.player | motion: motion}
      Players.update(self(), player)
      %{state | player: player}
    end
  end

  def count_motion_packet(state) do
    tick = Integer.floor_div(System.monotonic_time(:millisecond), 50)

    window =
      case state.motion_window do
        %{tick: ^tick} = window -> %{window | packets: window.packets + 1}
        _ -> %{tick: tick, packets: 1, first: Map.take(state.player, [:x, :y, :z])}
      end

    %{state | motion_window: window}
  end

  def motion_signature(state),
    do: {pose_signature(state), state.player.game_mode.current}

  def start_motion(
        %{life_stage: :alive, teleport_pending: false, motion_pending: input, jobs: jobs} = state
      )
      when input != nil and not is_map_key(jobs.active, :motion) do
    remaining = input.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      correct_motion(state, :movement_admission_timeout_corrections)
    else
      signature = motion_signature(state)

      prepared =
        case input.prepared do
          %{signature: ^signature, start: start} -> {:ok, start}
          _ -> PlayerMotionQuery.prepare(state.player, input.position, input.flags)
        end

      case prepared do
        {:ok, start} ->
          input = %{input | prepared: %{signature: signature, start: start}}
          admit_motion(%{state | motion_pending: input}, input, signature, start)

        {:error, _} ->
          correct_motion(state, :movement_geometry_corrections)
      end
    end
  end

  def start_motion(state), do: state

  def admit_motion(state, input, signature, start) do
    remaining = input.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      correct_motion(state, :movement_admission_timeout_corrections)
    else
      case start.() do
        {:ok, task} ->
          if input.retry, do: Process.cancel_timer(input.retry)
          Metrics.add(:movement_jobs_started)
          Metrics.add(:movement_admission_wait_ms, 250 - remaining)

          {jobs, _job} =
            Jobs.track(state.jobs, :motion, task,
              timeout: remaining,
              data: %{input: input, signature: signature}
            )

          %{state | motion_pending: %{input | retry: nil}, jobs: jobs}

        {:error, reason}
        when reason in [:collision_workers_busy, :collision_workers_unavailable] ->
          Metrics.add(:movement_pool_busy)

          if input.retry do
            state
          else
            timer = Process.send_after(self(), {:retry_motion, input.token}, 5)
            %{state | motion_pending: %{input | retry: timer}}
          end

        {:error, _} ->
          correct_motion(state, :movement_geometry_corrections)
      end
    end
  end

  @doc false
  def cancel_pose_job(state) do
    {_job, jobs} = Jobs.cancel(state.jobs, :pose)
    %{state | jobs: jobs}
  end

  @doc false
  def cancel_motion_job(state) do
    {_job, jobs} = Jobs.cancel(state.jobs, :motion)
    input = state.motion_pending
    if input && input.retry, do: Process.cancel_timer(input.retry)
    input = if input, do: %{input | retry: nil, prepared: nil}
    %{state | jobs: jobs, motion_pending: input}
  end

  def correct_motion(state, metric) do
    Metrics.add(metric)
    player = %{state.player | motion: PlayerMotion.corrected(state.player.motion)}
    relocate(state, player, false)
  end

  @doc false
  # Move the player to `player`'s pose with a teleport the client confirms;
  # `delta` is the movement the packet hands the client (a portal keeps the
  # entering velocity, VMC-026b).
  def relocate(state, player, reset_motion \\ true, delta \\ {0.0, 0.0, 0.0}) do
    state = state |> cancel_pose_job() |> Valimc.Player.Mining.cancel_mining()

    state =
      if state.table_job && state.table_job.kind == :open,
        do: Valimc.Player.Menus.fail_table_query(state),
        else: state

    state = Valimc.Player.Menus.begin_table_close(state)
    player = if reset_motion, do: %{player | motion: %PlayerMotion{}}, else: player

    if state.motion_pending && state.motion_pending.retry,
      do: Process.cancel_timer(state.motion_pending.retry)

    {_job, jobs} = Jobs.cancel(state.jobs, :motion)
    state = %{state | jobs: jobs}

    teleport = if state.teleport == 2_147_483_647, do: 0, else: state.teleport + 1
    send_packets(state, [Packets.teleport(player, teleport, delta)])
    Players.update(self(), player)
    send(self(), :drain)

    Valimc.Session.Replication.update_view(%{
      state
      | player: player,
        teleport: teleport,
        teleport_pending: true,
        login_velocity_pending: false,
        motion_pending: nil,
        motion_window: nil,
        pose_checked: nil,
        pose_generation: state.pose_generation + 1
    })
  end

  def pose_signature(state),
    do: {PlayerPoseQuery.signature(state.player), state.pose_generation}

  def sample_pose(
        %{life_stage: :alive, motion_pending: nil, teleport_pending: false, jobs: jobs} = state
      )
      when not is_map_key(jobs.active, :pose) do
    signature = pose_signature(state)

    active =
      state.simulation_due and
        (PlayerEnvironment.active?(state.player.environment) or
           state.player.fire_ticks > 0 or state.fire_damage_due or
           state.fire_contacts_active or
           Valimc.PlayerAir.supply(state.player) < Valimc.PlayerAir.maximum() or
           not state.player.motion.settled)

    if PlayerInput.loaded?(state.player.input) and (signature != state.pose_checked or active) do
      deadline = System.monotonic_time(:millisecond) + 250

      case PlayerPoseQuery.start(state.player) do
        {:ok, task} ->
          {jobs, _job} =
            Jobs.track(state.jobs, :pose, task, data: %{signature: signature, deadline: deadline})

          %{state | jobs: jobs}

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  def sample_pose(state), do: state

  def apply_kinetic_tick(state, result, packet_bounce) do
    {player, bounced} =
      if state.simulation_due do
        Metrics.add(:player_physics_ticks)
        motion = PlayerKinetics.apply_result(state.player.motion, result)
        {%{state.player | motion: motion}, packet_bounce or result.bounced}
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

    for pid <- Players.nearby(state.regions),
        pid != self(),
        do:
          Valimc.Connection.deliver(
            pid,
            {:player_packet, self(), state.player.entity_id, packet, framed}
          )

    state
  end

  def monitor_pose_sources(state, fences) do
    owners = MapSet.new(fences, fn {_, %{owner: owner}} -> owner end)

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
