defmodule Valimc.Connection do
  use GenServer, restart: :temporary, shutdown: 15_000

  @moduledoc "A socket-owning process per player, including their protocol and connection-local state."
  require Logger

  alias Valimc.Protocol.{
    ClientCommand,
    ClientTick,
    Data,
    EffectTypes,
    Encryption,
    Packets,
    Wire
  }

  alias Valimc.Session.Jobs
  alias Valimc.Session.Commands
  alias Valimc.Net.LoginFlow
  alias Valimc.Player.Placement
  alias Valimc.Player.Menus
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Transfers
  alias Valimc.Player.Mining
  alias Valimc.Session.Replication
  alias Valimc.Player.Movement
  alias Valimc.Player.ItemUse
  alias Valimc.Player.Vitals

  import Valimc.Net.Codec,
    only: [send_packets: 2, send_frames: 2, crypt_bytes: 3, reject: 2, reset_window: 1]

  alias Valimc.{
    ChatThrottle,
    CreativeInput,
    Inventory,
    Metrics,
    Players,
    PlayerAbilities,
    PlayerContainerQuery,
    PlayerAbsorption,
    PlayerAirEffects,
    PlayerEnvironment,
    PlayerEffects,
    PlayerHealth,
    PlayerInput,
    PlayerKinetics,
    PlayerMotion,
    PlayerMiningQuery,
    PlayerPickupIntent,
    PlayerSnapshot,
    PlayerStore,
    PlayerUse,
    TransferDelivery,
    World
  }

  alias Valimc.World.TickClock

  alias Valimc.World.{ChestLidReplication, EntityReplication, WeatherReplication}
  import Bitwise
  @fire_resistance EffectTypes.id("fire_resistance")
  @resistance EffectTypes.id("resistance")
  @absorption EffectTypes.id("absorption")
  @periodic_effects Enum.sort(Enum.map(~w(regeneration hunger poison wither), &EffectTypes.id/1))
  @live_effects [@fire_resistance, @resistance, @absorption, EffectTypes.id("water_breathing")] ++
                  Enum.map(
                    ~w(speed slowness nausea jump_boost slow_falling levitation),
                    &EffectTypes.id/1
                  ) ++
                  @periodic_effects
  @use_item_packet Data.id(:play, :serverbound, "use_item")
  @slab_tags Path.expand("../../priv/protocol/tags.json", __DIR__)
  @external_resource @slab_tags

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def start_link(socket), do: GenServer.start_link(__MODULE__, socket)

  @doc "Server-authorized relocation; expires rather than applying an abandoned queued call."
  def teleport(pid, destination) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:teleport, destination, deadline}, 1500)
  end

  @doc "Set a bounded server-authorized velocity without replacing the accepted position."
  def set_velocity(pid, velocity) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:set_velocity, velocity, deadline}, 1500)
  end

  @doc "Apply server-authorized fall damage on its player owner; landing validation is separate."
  def fall_damage(pid, amount) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:fall_damage, amount, deadline}, 1500)
  end

  @doc "Apply a supported effect on its player owner; duration state is bounded and server-authorized."
  def add_effect(pid, effect_id, incoming) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:effect, effect_id, incoming, deadline}, 1500)
  end

  @doc "Remove a supported effect on its player owner."
  def remove_effect(pid, effect_id) do
    deadline = System.monotonic_time(:millisecond) + 1000
    GenServer.call(pid, {:effect, effect_id, :remove, deadline}, 1500)
  end

  @impl true
  def handle_call(
        {:teleport, destination, deadline},
        _,
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and is_map(destination) and
         map_size(destination) == 5 and
         Enum.all?([:x, :y, :z, :yaw, :pitch], &Map.has_key?(destination, &1)) and
         PlayerStore.valid_pose?(destination) do
      {:reply, :ok, Movement.relocate(state, Map.merge(state.player, destination))}
    else
      {:reply, {:error, :invalid_or_expired_teleport}, state}
    end
  end

  def handle_call({:teleport, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

  def handle_call(
        {:set_velocity, velocity, deadline},
        _,
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and PlayerKinetics.valid_velocity?(velocity) and
         PlayerKinetics.admissible?(state.player, velocity) do
      state = state |> Movement.cancel_pose_job() |> Movement.cancel_motion_job()
      velocity = velocity |> Tuple.to_list() |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()
      motion = %{state.player.motion | velocity: velocity, settled: false}
      player = %{state.player | motion: motion}
      Players.update(self(), player)
      state = %{state | player: player, pose_checked: nil, login_velocity_pending: false}
      state = Movement.send_velocity(state, velocity)
      {:reply, :ok, state |> Movement.start_motion() |> Movement.sample_pose()}
    else
      {:reply, {:error, :invalid_or_expired_velocity}, state}
    end
  end

  def handle_call({:set_velocity, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

  def handle_call({:fall_damage, amount, deadline}, _, %{phase: :play} = state) do
    if System.monotonic_time(:millisecond) < deadline do
      case PlayerHealth.hurt_window(state.player.health, amount) do
        {:ok, selected} ->
          try do
            {result, next} = Vitals.apply_damage(state, selected, :fall)
            {:reply, {:ok, result}, next}
          catch
            {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
          end

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :expired_damage}, state}
    end
  end

  def handle_call({:fall_damage, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

  def handle_call(
        {:effect, id, incoming, deadline},
        _,
        %{phase: :play, life_stage: :alive} = state
      ) do
    if System.monotonic_time(:millisecond) < deadline and id in @live_effects do
      result =
        if incoming == :remove,
          do: PlayerEffects.remove(state.player.effects, id),
          else: PlayerEffects.add(state.player.effects, id, incoming)

      case result do
        {:ok, effects, changed} ->
          new = not Map.has_key?(state.player.effects, id)
          player = %{state.player | effects: effects}

          player =
            if id == @absorption and incoming != :remove,
              do: PlayerAbsorption.reconcile(player, elem(hd(incoming), 1)),
              else: PlayerAbsorption.reconcile(player)

          next = %{state | player: player}

          try do
            if changed do
              packet =
                if incoming == :remove,
                  do: Packets.remove_effect(player.entity_id, id),
                  else: Packets.update_effect(player.entity_id, id, hd(effects[id]), new)

              send_packets(next, [packet])
            end

            Players.update(self(), player)

            {:reply, {:ok, changed},
             next
             |> Movement.publish_movement_speed()
             |> Movement.publish_absorption()
             |> Movement.publish_jump_boost()}
          catch
            {:disconnect, _, current} -> {:stop, :normal, {:error, :disconnected}, current}
          end

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :invalid_or_expired_effect}, state}
    end
  end

  def handle_call({:effect, _, _, _}, _, state), do: {:reply, {:error, :not_playing}, state}

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
            Metrics.add(:slow_clients_disconnected)
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
  def init(socket) do
    Process.flag(:trap_exit, true)
    Process.flag(:message_queue_data, :off_heap)

    {:ok,
     %{
       socket: socket,
       phase: :handshake,
       step: nil,
       threshold: nil,
       protocol: nil,
       buffer: <<>>,
       cipher: nil,
       encryption_requested: Valimc.config(:encrypt_login) or Valimc.config(:online_mode),
       online_mode: Valimc.config(:online_mode),
       login_name: nil,
       key_challenge: nil,
       key_pair: nil,
       key_public: nil,
       key_job: nil,
       auth_job: nil,
       player: nil,
       client_tick: %ClientTick{},
       chat_throttle: ChatThrottle.new(),
       player_store: nil,
       store_fence: nil,
       store_monitor: nil,
       save_ref: nil,
       use_save: nil,
       active_use: nil,
       mining: nil,
       mining_water: false,
       placement_queue: :queue.new(),
       placement_queued: 0,
       table_menu: nil,
       chest_lids: %ChestLidReplication{},
       table_counter: 0,
       table_job: nil,
       table_queue: :queue.new(),
       table_queued: 0,
       table_closing: false,
       crafting_repeat: nil,
       life_save: nil,
       life_stage: :alive,
       respawn_requested: false,
       recovery: nil,
       experience_after: System.monotonic_time(:millisecond),
       pickup_cursor: 0,
       creative_input: CreativeInput.new(CreativeInventory.creative_tick()),
       creative_drain_scheduled: false,
       chunks: MapSet.new(),
       regions: MapSet.new(),
       pending: [],
       batch_pending: false,
       peers: %{},
       player_flags_view: 0,
       equipment_source: nil,
       pose_checked: nil,
       pose_generation: 0,
       pose_sources: %{},
       jobs: Jobs.new(),
       motion_pending: nil,
       motion_window: nil,
       simulation_clock: nil,
       movement_speed_view: nil,
       absorption_view: nil,
       jump_boost_view: nil,
       food_tick_origin: 0,
       simulation_due: false,
       air_policy: :none,
       environment_effects: %{},
       fire_damage_due: false,
       fire_contacts_active: false,
       armor_view: nil,
       entity_replication: EntityReplication.new(),
       entity_cache: %{},
       clock_version: nil,
       weather_view: nil,
       difficulty_view: nil,
       outbound: [],
       # Admission derives permissions from the server-selected or saved mode.
       inventory: Inventory.new(),
       window: System.monotonic_time(:second),
       packets: 0,
       bytes: 0,
       logical_bytes: 0,
       keepalive: nil,
       teleport: 1,
       teleport_pending: true,
       login_velocity_pending: false,
       center: nil,
       active: false
     }}
  end

  @impl true
  # Session jobs (`Valimc.Session.Jobs`) claim their results, DOWNs and timeouts
  # first; everything else goes to the per-message clauses below.
  def handle_info(message, %{jobs: %Jobs{}} = state) do
    case Jobs.classify(state.jobs, message) do
      {:result, kind, job, payload, jobs} -> job_result(kind, job, payload, %{state | jobs: jobs})
      {:down, kind, job, reason, jobs} -> job_down(kind, job, reason, %{state | jobs: jobs})
      {:timeout, kind, job, jobs} -> job_timeout(kind, job, %{state | jobs: jobs})
      :stale -> {:noreply, state}
      :unknown -> info(message, state)
    end
  end

  def handle_info(message, state), do: info(message, state)

  defp job_result(:pose, job, result, state) do
    guard_connection(state, fn ->
      case result do
        {:ok,
         %{
           pose: pose,
           swimming: swimming,
           fences: fences,
           powder_snow: powder,
           submerged: submerged,
           eye_water: eye_water,
           kinetics: kinetics
         }} ->
          if System.monotonic_time(:millisecond) < job.deadline and
               Movement.pose_signature(state) == job.signature and
               Enum.all?(fences, fn {key, %{owner: owner}} ->
                 World.existing_owner(key) == {:ok, owner}
               end) do
            player = %{
              state.player
              | pose: pose,
                motion: %{state.player.motion | swimming: swimming}
            }

            if pose != state.player.pose do
              send_packets(state, [Packets.player_pose(player)])
            end

            state =
              %{state | player: player}
              |> Movement.apply_kinetic_tick(kinetics, false)
              |> Vitals.observe_environment(powder, submerged, eye_water, kinetics)
              |> Movement.monitor_pose_sources(fences)

            state =
              if state.life_stage == :alive,
                do: %{state | pose_checked: Movement.pose_signature(state)},
                else: state

            {:noreply, state}
          else
            {:noreply, state}
          end

        {:error, _} ->
          {:noreply, state}
      end
    end)
  end

  defp job_result(:pickup, job, result, state) do
    guard_connection(state, fn ->
      case result do
        {:ok, reservation} -> {:noreply, Transfers.prepare_pickup(state, job, reservation)}
        _ -> {:noreply, state}
      end
    end)
  end

  defp job_result(:mining, job, result, state) do
    guard_connection(state, fn ->
      if System.monotonic_time(:millisecond) < job.deadline do
        {:noreply, Mining.mining_result(state, job, result)}
      else
        if job.stage == :reserve and match?({:ok, %{owner: _, permit: _}}, result),
          do: PlayerMiningQuery.release(elem(result, 1))

        state = Mining.cancel_mining(state)

        {:noreply,
         if(job.stage == :correct, do: state, else: Mining.correct_mining(state, job.position))}
      end
    end)
  end

  defp job_result(:placement, job, result, state) do
    guard_connection(state, fn ->
      case result do
        {:reserved, reservation} ->
          {:noreply, Placement.prepare_survival_placement(state, job.command, reservation)}

        {:ok, _outcome} ->
          state =
            if job.command.body == nil, do: CreativeInventory.resync_inventory(state), else: state

          send_packets(state, [Packets.ack(job.command.request.sequence)])
          {:noreply, state |> Vitals.continue_life() |> Placement.drain_placements()}

        _ ->
          reject(state, "Block interaction unavailable; please reconnect")
      end
    end)
  end

  defp job_result(:motion, job, result, state) do
    guard_connection(state, fn ->
      cond do
        System.monotonic_time(:millisecond) >= job.input.deadline ->
          {:noreply, Movement.correct_motion(state, :movement_late_result_corrections)}

        Movement.motion_signature(state) != job.signature ->
          {:noreply, Movement.start_motion(state)}

        true ->
          case result do
            {:ok,
             %{
               accepted: true,
               pose: pose,
               swimming: swimming,
               fences: fences,
               powder_snow: powder,
               submerged: submerged,
               eye_water: eye_water,
               exhaustion: exhaustion,
               kinetics: kinetics,
               landing: landing
             }} ->
              if Enum.all?(fences, fn {key, %{owner: owner}} ->
                   World.existing_owner(key) == {:ok, owner}
                 end) do
                player = state.player |> Map.merge(job.input.position) |> Map.put(:pose, pose)

                movement =
                  {player.x - state.player.x, player.y - state.player.y,
                   player.z - state.player.z}

                motion =
                  PlayerMotion.accept(
                    state.player.motion,
                    movement,
                    job.input.flags,
                    player.abilities.flying
                  )

                motion =
                  PlayerKinetics.apply_result(%{motion | swimming: swimming}, kinetics.packet)

                player = %{player | motion: motion}

                if pose != state.player.pose,
                  do: send_packets(state, [Packets.player_pose(player)])

                next = %{
                  state
                  | player: player,
                    motion_pending: nil,
                    pose_checked: nil
                }

                send(self(), :drain)

                next =
                  next
                  |> Vitals.apply_movement_exhaustion(exhaustion)
                  |> Movement.apply_kinetic_tick(kinetics.tick, kinetics.packet.bounced)
                  |> Vitals.observe_environment(powder, submerged, eye_water, kinetics.tick)
                  |> Movement.monitor_pose_sources(fences)
                  |> Replication.update_view()
                  |> Vitals.apply_landing(landing)

                {:noreply,
                 if(next.life_stage == :alive,
                   do: %{next | pose_checked: Movement.pose_signature(next)},
                   else: next
                 )}
              else
                {:noreply, Movement.correct_motion(state, :movement_source_corrections)}
              end

            {:ok, %{accepted: false}} ->
              {:noreply, Movement.correct_motion(state, :movement_collision_corrections)}

            {:error, reason} ->
              metric =
                if reason == :collision_query_timeout,
                  do: :movement_query_timeout_corrections,
                  else: :movement_geometry_corrections

              {:noreply, Movement.correct_motion(state, metric)}
          end
      end
    end)
  end

  defp job_result(:experience, job, result, state) do
    guard_connection(state, fn ->
      with {:ok, request} <- result,
           true <- Transfers.experience_current?(state, job),
           true <- Map.delete(request, :permit) == Map.delete(job.intent.request, :permit) do
        state = Transfers.cancel_experience_query(state)
        ref = make_ref()
        snapshot = PlayerSnapshot.capture(state.player, state.inventory)
        intent = %{job.intent | request: request}

        recovery = %{
          Transfers.new_recovery(:play, :prepare, nil)
          | ref: ref,
            plan: %{
              key: intent.key,
              records: [],
              inventory: state.inventory,
              intent: intent,
              snapshot: snapshot
            }
        }

        PlayerStore.prepare_container(
          state.player_store,
          state.store_fence,
          snapshot,
          intent,
          ref
        )

        {:noreply, %{state | recovery: recovery}}
      else
        _ -> {:noreply, Transfers.cancel_experience_query(state)}
      end
    end)
  end

  defp job_down(:motion, _job, _reason, state),
    do:
      guard_connection(state, fn ->
        {:noreply, Movement.correct_motion(state, :movement_geometry_corrections)}
      end)

  defp job_down(:placement, _job, _reason, state),
    do:
      guard_connection(state, fn ->
        reject(state, "Block interaction failed; please reconnect")
      end)

  defp job_down(:mining, _job, _reason, state),
    do: guard_connection(state, fn -> {:noreply, Mining.cancel_mining(state)} end)

  defp job_down(kind, _job, _reason, state) when kind in [:pose, :pickup, :experience],
    do: {:noreply, state}

  defp job_timeout(:motion, _job, state),
    do:
      guard_connection(state, fn ->
        {:noreply, Movement.correct_motion(state, :movement_worker_deadline_corrections)}
      end)

  defp job_timeout(:placement, _job, state),
    do:
      guard_connection(state, fn ->
        reject(state, "Block interaction timed out; please reconnect")
      end)

  defp job_timeout(:mining, _job, state),
    do: guard_connection(state, fn -> {:noreply, Mining.cancel_mining(state)} end)

  defp job_timeout(_kind, _job, state), do: {:noreply, state}

  defp info(:activate, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    Process.send_after(self(), :login_deadline, Valimc.config(:login_timeout_ms))
    Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))
    Metrics.add(:connections_accepted)
    {:noreply, %{state | active: true}}
  end

  defp info({:tcp, socket, data}, %{socket: socket} = state) do
    guard_connection(state, fn ->
      state = reset_window(state)
      bytes = state.bytes + byte_size(data)
      if bytes > Valimc.config(:bytes_per_second), do: reject(state, "Inbound byte rate exceeded")

      if byte_size(state.buffer) + byte_size(data) > Valimc.config(:max_packet_bytes) + 5,
        do: reject(state, "Receive buffer exceeded")

      data = crypt_bytes(state.cipher, :decrypt, data)
      consume(%{state | buffer: state.buffer <> data, bytes: bytes, active: false}, 64)
    end)
  end

  defp info(:drain, state), do: guard_connection(state, fn -> consume(state, 64) end)
  defp info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  defp info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  defp info(
         {:key_verified, worker, token, result},
         %{key_job: %{pid: worker, token: token} = job} = state
       ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.KeyExchange.cancel(job)
    state = %{state | key_job: nil}

    guard_connection(state, fn ->
      if System.monotonic_time(:millisecond) >= job.deadline,
        do: reject(state, "Login encryption timed out")

      case result do
        {:ok, secret} ->
          {:ok, cipher} = Encryption.new(secret)
          # This tail followed the plaintext key frame and has never been decrypted.
          state = %{
            state
            | cipher: cipher,
              buffer: crypt_bytes(cipher, :decrypt, state.buffer),
              step: nil
          }

          if state.online_mode do
            digest = Encryption.server_hash(secret, state.key_public)
            token = make_ref()

            case Valimc.Auth.SessionJobs.start(self(), token, state.login_name, digest) do
              {:ok, job} ->
                timeout = max(job.deadline - System.monotonic_time(:millisecond), 0)
                timer = Process.send_after(self(), {:session_deadline, token}, timeout)
                Valimc.Auth.SessionJobs.activate(job)

                {:noreply,
                 %{
                   state
                   | step: :auth_job,
                     auth_job: Map.put(job, :timer, timer),
                     key_public: nil
                 }}

              _ ->
                reject(state, "Authentication busy; please retry")
            end
          else
            state = LoginFlow.start_player_login(%{state | key_public: nil}, state.login_name)
            consume(state, 64)
          end

        _ ->
          reject(state, "Invalid login encryption response")
      end
    end)
  end

  defp info({:key_verified, _, _, _}, state), do: {:noreply, state}

  defp info(
         {:session_verified, worker, token, result},
         %{auth_job: %{pid: worker, token: token} = job} = state
       ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.Auth.SessionJobs.cancel(job)
    state = %{state | auth_job: nil}

    guard_connection(state, fn ->
      if System.monotonic_time(:millisecond) >= job.deadline,
        do: reject(state, "Authentication timed out")

      case result do
        {:ok, profile} ->
          if not Valimc.Auth.Profile.valid?(profile, state.login_name),
            do: reject(state, "Invalid authentication profile")

          state = LoginFlow.start_player_login(%{state | step: nil}, state.login_name, profile)
          consume(state, 64)

        {:error, :unverified_session} ->
          reject(state, "Failed to verify username")

        _ ->
          reject(state, "Authentication servers unavailable; please retry")
      end
    end)
  end

  defp info({:session_verified, _, _, _}, state), do: {:noreply, state}

  defp info({:session_deadline, token}, %{auth_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do: guard_connection(state, fn -> reject(state, "Authentication timed out") end),
      else: {:noreply, state}
  end

  defp info({:session_deadline, _}, state), do: {:noreply, state}

  defp info({:DOWN, ref, :process, _, _}, %{auth_job: %{monitor: ref}} = state),
    do:
      guard_connection(state, fn ->
        reject(state, "Authentication servers unavailable; please retry")
      end)

  defp info({:key_deadline, token}, %{key_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do: guard_connection(state, fn -> reject(state, "Login encryption timed out") end),
      else: {:noreply, state}
  end

  defp info({:key_deadline, _}, state), do: {:noreply, state}

  defp info({:DOWN, ref, :process, _, _}, %{key_job: %{monitor: ref}} = state),
    do: guard_connection(state, fn -> reject(state, "Login encryption unavailable") end)

  defp info({:table_deadline, ref}, %{table_job: %{ref: ref}} = state),
    do: guard_connection(state, fn -> {:noreply, Menus.fail_table_query(state)} end)

  defp info({:table_deadline, _}, state), do: {:noreply, state}

  defp info(
         {:DOWN, ref, :process, _, _},
         %{table_menu: %{kind: kind, monitor: ref}} = state
       )
       when kind in [:chest, :cooking],
       do: guard_connection(state, fn -> {:noreply, Menus.begin_table_close(state)} end)

  defp info({:DOWN, ref, :process, _, _}, %{table_job: %{monitor: ref}} = state),
    do: guard_connection(state, fn -> {:noreply, Menus.fail_table_query(state)} end)

  defp info(
         {:container_candidate, ref, result},
         %{jobs: %{active: %{experience: %{ref: ref, stage: :candidate} = job}}} = state
       ) do
    guard_connection(state, fn ->
      with {:ok, intent} <- result,
           true <- Transfers.experience_current?(state, job),
           {:ok, task} <- PlayerContainerQuery.start(job.owner, intent.request, job.actor) do
        jobs = Jobs.update(state.jobs, :experience, %{intent: intent, stage: :admit})
        {jobs, _job} = Jobs.attach(jobs, :experience, task)
        {:noreply, %{state | jobs: jobs}}
      else
        _ -> {:noreply, Transfers.cancel_experience_query(state)}
      end
    end)
  end

  defp info(
         {:container_candidate, ref, result},
         %{table_job: %{kind: :container, stage: :candidate, ref: ref} = job} = state
       ) do
    guard_connection(state, fn ->
      next =
        case result do
          {:ok, intent} ->
            if Menus.container_action_current?(state, job),
              do: Menus.admit_container_action(state, intent),
              else: Menus.fail_chest_action(state)

          _ ->
            Menus.fail_chest_action(state)
        end

      {:noreply, next}
    end)
  end

  defp info({:container_candidate, _, _}, state), do: {:noreply, state}

  defp info(
         {ref, result},
         %{table_job: %{kind: :container, task: %Task{ref: ref}} = job} = state
       ) do
    Process.demonitor(ref, [:flush])
    state = %{state | table_job: %{job | task: nil}}

    guard_connection(state, fn ->
      next =
        with {:ok, request} <- result,
             true <- Menus.container_action_current?(state, job),
             true <- Map.delete(request, :permit) == Map.delete(job.intent.request, :permit),
             true <- System.monotonic_time(:millisecond) < job.actor.expires do
          Menus.prepare_chest_action(state, %{job.intent | request: request})
        else
          _ -> Menus.fail_chest_action(state)
        end

      {:noreply, next}
    end)
  end

  defp info(
         {:DOWN, ref, :process, _, _},
         %{table_job: %{kind: :container, task: %Task{ref: ref}}} = state
       ),
       do: guard_connection(state, fn -> {:noreply, Menus.fail_chest_action(state)} end)

  defp info(:save_player, state) do
    Process.send_after(self(), :save_player, Valimc.config(:player_save_interval_ms))

    if state.phase == :play and state.save_ref == nil and not inventory_pending(state) do
      ref = make_ref()

      PlayerStore.checkpoint(
        state.player_store,
        state.store_fence,
        PlayerSnapshot.capture(state.player, state.inventory),
        ref
      )

      Process.send_after(self(), {:save_deadline, ref}, 5000)
      {:noreply, %{state | save_ref: ref}}
    else
      {:noreply, state}
    end
  end

  defp info({:player_saved, ref, :ok}, %{life_save: %{ref: ref} = save} = state) do
    guard_connection(state, fn ->
      state = %{state | life_save: if(save.kind == :respawn, do: save, else: nil), save_ref: nil}

      state =
        case save.kind do
          :death_mark ->
            Vitals.continue_life(%{state | life_stage: :dropping})

          :death_done ->
            state = %{
              state
              | inventory: Transfers.recovered_inventory(state, save.snapshot),
                life_stage: :dead
            }

            if state.phase == :login,
              do: LoginFlow.finish_login(state),
              else: Vitals.continue_life(state)

          :respawn ->
            Vitals.finish_respawn(state, save.player)
        end

      {:noreply, state}
    end)
  end

  defp info({:player_saved, ref, :ok}, %{save_ref: ref} = state),
    do:
      guard_connection(state, fn ->
        {:noreply,
         %{state | save_ref: nil, use_save: nil}
         |> CreativeInventory.drain_creative()
         |> Vitals.continue_life()
         |> Menus.continue_table_close()
         |> Menus.continue_crafting_repeat()
         |> Menus.drain_table_clicks()
         |> Placement.drain_placements()}
      end)

  defp info(:drain_creative, %{creative_drain_scheduled: true} = state),
    do:
      guard_connection(state, fn ->
        {:noreply,
         state
         |> Map.put(:creative_drain_scheduled, false)
         |> CreativeInventory.drain_creative()
         |> CreativeInventory.sync_creative_result()}
      end)

  defp info(:drain_creative, state), do: {:noreply, state}

  defp info({:player_saved, ref, {:error, _}}, %{save_ref: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player save failed") end)

  defp info({:save_deadline, ref}, %{save_ref: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player save timed out") end)

  defp info({:save_deadline, _}, state), do: {:noreply, state}

  defp info(
         {:transfer_delivered, worker, token, result},
         %{recovery: %{stage: :delivery, job: %{pid: worker, token: token} = job} = recovery} =
           state
       ) do
    Process.demonitor(job.monitor, [:flush])
    state = %{state | recovery: %{recovery | job: nil}}

    guard_connection(state, fn ->
      if TransferDelivery.completed?(state.recovery.intent, result) do
        ref = make_ref()
        PlayerStore.complete_transfer(state.player_store, state.store_fence, ref)
        {:noreply, %{state | recovery: %{state.recovery | stage: :complete, ref: ref}}}
      else
        {:noreply, Transfers.recovery_failure(state, result)}
      end
    end)
  end

  defp info({:transfer_delivered, _, _, _}, state), do: {:noreply, state}

  defp info(
         {:player_transfer_saved, ref, {:ok, fence, snapshot}},
         %{recovery: %{stage: :prepare, ref: ref, plan: plan} = recovery} = state
       ) do
    guard_connection(state, fn ->
      expected_outbox =
        if plan[:intent] && plan.intent[:kind] == :pickup do
          intent =
            %{
              plan.intent
              | request:
                  Map.merge(
                    plan.intent.request,
                    %{source: state.player.uuid, sequence: snapshot.transfer_sequence}
                  )
            }

          {:ok, intent} = PlayerPickupIntent.bind(intent, plan.snapshot)
          intent
        else
          Map.get(plan, :intent, %{key: plan.key, records: plan.records})
        end

      if snapshot.outbox != expected_outbox or
           snapshot.inventory.slots != plan.inventory.slots or
           snapshot.inventory.carried != plan.inventory.carried or
           snapshot.inventory.selected != plan.inventory.selected or
           snapshot.inventory.table_inputs != plan.inventory.table_inputs,
         do: reject(state, "Inventory transfer returned inconsistent state")

      recovery = %{
        recovery
        | stage: :delivery,
          intent: Map.take(snapshot, [:outbox, :transfer_sequence]),
          ref: nil
      }

      state = %{state | recovery: recovery, store_fence: fence}
      state = %{state | inventory: Transfers.recovered_inventory(state, snapshot)}

      state =
        if recovery.mode == :login or state.life_stage != :alive or
             CreativeInventory.creative_pending?(state),
           do: state,
           else: CreativeInventory.resync_inventory(state)

      {:noreply, Transfers.deliver_recovery(state)}
    end)
  end

  defp info(
         {:player_transfer_saved, ref, {:error, reason}},
         %{recovery: %{stage: :prepare, ref: ref} = recovery} = state
       ) do
    guard_connection(state, fn ->
      if reason == :player_commit_uncertain,
        do: reject(state, "Inventory transfer commit is uncertain; reconnect to recover")

      if recovery.mode == :death,
        do: reject(state, "Death inventory cleanup could not be committed; reconnect to recover")

      if state.table_closing and state.inventory.table_inputs != nil,
        do: reject(state, "Table cleanup could not be committed; reconnect to recover")

      if recovery.mode == :login,
        do:
          reject(
            state,
            "Disconnected inventory cleanup could not be prepared; please retry later"
          )

      Process.cancel_timer(recovery.timer)
      state = %{state | table_closing: false, crafting_repeat: nil}

      send_packets(state, [
        Packets.chat("Item operation could not be prepared; inventory restored")
      ])

      {:noreply,
       state
       |> Map.put(:recovery, nil)
       |> Mining.correct_block_recovery(recovery)
       |> CreativeInventory.drain_creative()
       |> CreativeInventory.sync_creative_result()
       |> Vitals.continue_life()
       |> Placement.drain_placements()}
    end)
  end

  defp info(
         {:player_transfer_saved, ref, {:ok, fence, snapshot}},
         %{recovery: %{stage: :complete, ref: ref} = recovery} = state
       ) do
    guard_connection(state, fn ->
      if snapshot.outbox != nil or snapshot.transfer_sequence != recovery.intent.transfer_sequence,
        do: reject(state, "Inventory recovery returned inconsistent state")

      Process.cancel_timer(recovery.timer)
      inventory = Transfers.recovered_inventory(state, snapshot)
      previous_progression = state.player.progression
      state = %{state | recovery: nil, store_fence: fence, inventory: inventory}

      state =
        if Map.has_key?(snapshot, :progression),
          do: put_in(state.player.progression, snapshot.progression),
          else: state

      state =
        if recovery.intent.outbox[:request] &&
             recovery.intent.outbox.request[:kind] == :experience,
           do: %{state | experience_after: System.monotonic_time(:millisecond) + 100},
           else: state

      if recovery.mode != :login do
        if previous_progression.experience != state.player.progression.experience,
          do: send_packets(state, [Packets.experience(state.player.progression.experience)])

        learned =
          MapSet.difference(state.player.progression.recipes, previous_progression.recipes)

        if MapSet.size(learned) > 0,
          do: send_packets(state, [Valimc.CookingRecipeBook.packet(learned, false, true)])
      end

      state = Mining.correct_block_recovery(state, recovery)

      {:noreply,
       if(recovery.mode == :login,
         do: LoginFlow.reconcile_login(state),
         else:
           state
           |> CreativeInventory.drain_creative()
           |> CreativeInventory.sync_recovery_inventory(recovery)
           |> Vitals.continue_life()
           |> Menus.continue_table_close()
           |> Menus.continue_crafting_repeat()
           |> Menus.drain_table_clicks()
           |> Placement.drain_placements()
       )}
    end)
  end

  defp info(
         {:player_transfer_saved, ref, {:error, _} = error},
         %{recovery: %{stage: :complete, ref: ref}} = state
       ),
       do: guard_connection(state, fn -> {:noreply, Transfers.recovery_failure(state, error)} end)

  defp info({:player_transfer_saved, _, _}, state), do: {:noreply, state}

  defp info(
         {:retry_recovery, id, token},
         %{recovery: %{id: id, stage: :retry, retry_token: token} = recovery} = state
       ) do
    state = %{state | recovery: %{recovery | retry_timer: nil}}
    guard_connection(state, fn -> {:noreply, Transfers.deliver_recovery(state)} end)
  end

  defp info({:retry_recovery, _, _}, state), do: {:noreply, state}

  defp info({:recovery_deadline, id}, %{recovery: %{id: id}} = state),
    do:
      guard_connection(state, fn ->
        reject(state, "Inventory recovery is still pending; please retry later")
      end)

  defp info({:recovery_deadline, _}, state), do: {:noreply, state}

  defp info(
         {:DOWN, monitor, :process, worker, _},
         %{recovery: %{stage: :delivery, job: %{pid: worker, monitor: monitor}} = recovery} =
           state
       ) do
    state = %{state | recovery: %{recovery | job: nil}}

    guard_connection(state, fn ->
      {:noreply, Transfers.recovery_failure(state, {:error, :region_restarting})}
    end)
  end

  defp info({:retry_motion, token}, %{motion_pending: %{token: token} = input} = state),
    do:
      guard_connection(state, fn ->
        {:noreply, Movement.start_motion(%{state | motion_pending: %{input | retry: nil}})}
      end)

  defp info({:retry_motion, _}, state), do: {:noreply, state}

  # Cancelling geometry retires its reference; a result already in this mailbox
  # must never become a new player input or crash a healthy connection.
  defp info({ref, _}, state) when is_reference(ref), do: {:noreply, state}

  defp info({:DOWN, ref, :process, _, _}, %{store_monitor: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player storage stopped") end)

  defp info({:DOWN, ref, :process, pid, _}, state) do
    {lids, closed} = ChestLidReplication.down(state.chest_lids, ref, pid)
    send_packets(state, Enum.map(closed, &Packets.chest_lid(&1, false)))
    state = %{state | chest_lids: lids}

    if Map.has_key?(state.pose_sources, ref) do
      {:noreply,
       %{
         state
         | pose_sources: Map.delete(state.pose_sources, ref),
           pose_generation: state.pose_generation + 1,
           pose_checked: nil
       }}
    else
      {:noreply, state}
    end
  end

  defp info(:login_deadline, %{phase: :play} = state), do: {:noreply, state}
  defp info(:login_deadline, state), do: {:stop, :normal, state}

  defp info(:keepalive, state) do
    guard_connection(state, fn ->
      Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))

      if state.phase == :play do
        now = System.monotonic_time(:millisecond)
        timeout = Valimc.config(:keepalive_timeout_ms)

        case state.keepalive do
          {_, sent} when now - sent > timeout ->
            reject(state, "Keepalive timed out")

          nil ->
            id = System.unique_integer([:positive])
            send_packets(state, [Packets.packet("keep_alive", <<id::signed-64>>)])
            {:noreply, %{state | keepalive: {id, now}}}

          _ ->
            {:noreply, state}
        end
      else
        {:noreply, state}
      end
    end)
  end

  defp info(
         {:player_tick, token},
         %{phase: :play, simulation_clock: %TickClock{} = clock} = state
       ) do
    guard_connection(state, fn ->
      case TickClock.advance(clock, token, System.monotonic_time(:millisecond)) do
        {:ok, next, late, delay} ->
          Process.send_after(self(), {:player_tick, next.token}, delay)
          Metrics.add(:player_ticks)
          if late > 0, do: Metrics.add(:player_tick_lateness_ms, late)

          player = %{
            state.player
            | health: PlayerHealth.tick(state.player.health),
              environment:
                PlayerEnvironment.tick(state.player.environment, state.life_stage == :alive)
          }

          if state.player.health.death_ticks < 20 and player.health.death_ticks == 20,
            do: Movement.broadcast_player_packet(state, Packets.remove_entity(player))

          state = %{
            state
            | player: player,
              simulation_clock: next,
              simulation_due: true,
              air_policy: PlayerAirEffects.policy(player.effects),
              # Base-step damage precedes expiry; retain only its relevant level
              # while bounded geometry samples coalesce to the latest admitted tick.
              environment_effects: Map.take(player.effects, [@resistance])
          }

          state = Vitals.tick_burning(state)
          state = Vitals.tick_effects(state)

          {:noreply,
           state
           |> Vitals.apply_void_damage()
           |> ItemUse.tick_item_use()
           |> Vitals.tick_food()
           |> Vitals.reset_effect_fall()
           |> Mining.tick_mining()
           |> Menus.continue_table_close()
           |> Menus.continue_crafting_repeat()
           |> Menus.check_table_menu()
           |> Movement.start_motion()
           |> Movement.sample_pose()}

        {:early, next, delay} ->
          Process.send_after(self(), {:player_tick, next.token}, delay)
          {:noreply, %{state | simulation_clock: next}}

        :stale ->
          {:noreply, state}
      end
    end)
  end

  defp info({:player_tick, _}, state), do: {:noreply, state}

  defp info(:publish_movement, state) do
    guard_connection(state, fn ->
      if state.phase == :play do
        Process.send_after(self(), :publish_movement, 50)

        state =
          Movement.update_player_input(
            ItemUse.publish_equipment(state),
            PlayerInput.tick(state.player.input)
          )
          |> Movement.start_motion()
          |> Movement.sample_pose()

        state =
          if state.player_flags_view != Packets.shared_flags(state.player) do
            state =
              Replication.emit_peer_packets(state, [Packets.player_flags(state.player)], :buffer)

            %{state | player_flags_view: Packets.shared_flags(state.player)}
          else
            state
          end

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

        # One tracker for every entity kind; unchanged chunks are not re-read.
        {desired, cache} = World.visible_entities(state.regions, state.chunks, state.entity_cache)
        state = %{state | entity_cache: cache}

        state =
          Transfers.start_pickup_query(
            state,
            for({id, %{kind: :item} = v} <- desired, into: %{}, do: {id, v})
          )

        state =
          Transfers.start_experience_query(
            state,
            for({id, %{kind: :orb} = v} <- desired, into: %{}, do: {id, v})
          )

        {replication, packets} = EntityReplication.reconcile(state.entity_replication, desired)

        state =
          Replication.emit_peer_packets(
            %{state | entity_replication: replication},
            packets,
            :buffer
          )

        {version, clock_packet} = Valimc.World.Clock.publication()

        state =
          if version != state.clock_version do
            %{state | clock_version: version, outbound: [clock_packet | state.outbound]}
          else
            state
          end

        {weather_view, weather_packets} =
          WeatherReplication.reconcile(state.weather_view, Valimc.World.Clock.weather())

        state =
          Replication.emit_peer_packets(
            %{state | weather_view: weather_view},
            weather_packets,
            :buffer
          )

        {difficulty, difficulty_packet} = Valimc.World.Clock.difficulty()

        state =
          if state.difficulty_view != difficulty,
            do:
              Replication.emit_peer_packets(
                %{state | difficulty_view: difficulty},
                [difficulty_packet],
                :buffer
              ),
            else: state

        packets = state.outbound |> Enum.reverse() |> List.flatten()
        send_packets(state, packets)

        {:noreply, %{state | outbound: []}}
      else
        {:noreply, state}
      end
    end)
  end

  defp info(:send_chunks, state),
    do: guard_connection(state, fn -> {:noreply, Replication.stream_chunks(state)} end)

  defp info({:event, event}, state) do
    guard_connection(state, fn -> {:noreply, event(state, event)} end)
  end

  # Overload is signalled, not killed, so terminate/2 still saves and releases jobs.
  defp info({:EXIT, _from, {:shutdown, :overloaded} = reason}, state),
    do: {:stop, reason, state}

  defp info({:EXIT, _from, :normal}, state), do: {:noreply, state}

  defp info({:EXIT, _from, reason}, state),
    do: {:stop, {:shutdown, {:linked_exit, reason}}, state}

  defp info(message, state) do
    Logger.warning("Connection ignored unexpected message: #{inspect(message, limit: 8)}")
    {:noreply, state}
  end

  defp guard_connection(state, work) do
    work.()
  rescue
    exception ->
      # Malformed input and server defects both end the session; never silently.
      Metrics.add(:malformed_connections)

      Logger.warning(
        "Connection closed after exception: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:stop, :normal, state}
  catch
    {:disconnect, _reason, current} -> {:stop, :normal, current}
    {:disconnect, _reason} -> {:stop, :normal, state}
  end

  defp consume(%{step: step} = state, _) when step in [:key_job, :auth_job],
    do: {:noreply, %{state | active: false}}

  # Preserve wire order for movement-dependent interactions and transfers. The
  # socket stays passive while its one input is validated; the owner itself
  # remains responsive to timers, server calls and worker/source messages.
  defp consume(%{motion_pending: pending} = state, _) when pending != nil,
    do: {:noreply, state}

  defp consume(state, 0) do
    send(self(), :drain)
    {:noreply, state}
  end

  defp consume(state, remaining) do
    # Leave the exception boundary before recursing so the 64-packet drain does
    # not grow a stack of guards. A failed frame retains earlier accepted state.
    case guard_connection(state, fn -> consume_packet(state) end) do
      {:continue, next} -> consume(next, remaining - 1)
      result -> result
    end
  end

  defp consume_packet(state) do
    case Wire.next_frame(state.buffer, Valimc.config(:max_packet_bytes), state.threshold) do
      :more ->
        :ok = :inet.setopts(state.socket, active: :once)
        {:noreply, %{state | active: true}}

      {:error, _} ->
        reject(state, "Malformed packet")

      # Preserve the client's fallback until its preceding block-use decision.
      # Earlier chat/control frames and owner clocks remain responsive. The
      # bounded receive buffer holds this frame until admission/deadline drains it.
      {:ok, @use_item_packet, _, _}
      when state.phase == :play and state.table_job != nil and state.table_job.kind == :open ->
        {:noreply, state}

      {:ok, id, payload, tail} ->
        state = reset_window(state)
        logical_bytes = state.logical_bytes + byte_size(payload)

        if logical_bytes > Valimc.config(:bytes_per_second),
          do: reject(state, "Decoded byte rate exceeded")

        state = %{state | logical_bytes: logical_bytes}

        if state.packets >= Valimc.config(:packets_per_second),
          do: reject(state, "Packet rate exceeded")

        Metrics.add(:packets_received)
        state = handle_packet(%{state | buffer: tail, packets: state.packets + 1}, id, payload)
        {:continue, state}
    end
  end

  defp handle_packet(%{phase: :handshake} = state, 0, payload) do
    {version, payload} = Wire.take_varint(payload)
    {_host, payload} = Wire.take_string(payload, 255)
    <<_port::16, payload::binary>> = payload
    {intent, <<>>} = Wire.take_varint(payload)

    case intent do
      1 ->
        %{state | phase: :status, protocol: version}

      2 ->
        state = %{state | phase: :login, protocol: version, step: :hello}

        if version != Valimc.protocol_version(),
          do: reject(state, "Use Minecraft Java #{Valimc.version()}")

        state

      _ ->
        reject(state, "Unsupported handshake intent")
    end
  end

  defp handle_packet(%{phase: :status} = state, 0, <<>>) do
    response =
      :json.encode(%{
        version: %{name: "ValiMC #{Valimc.version()}", protocol: Valimc.protocol_version()},
        players: %{max: Valimc.config(:max_players), online: Players.count(), sample: []},
        description: %{text: Valimc.config(:motd)},
        enforcesSecureChat: false
      })
      |> IO.iodata_to_binary()

    send_packets(state, [Packets.packet("status_response", Wire.string(response), :status)])
    state
  end

  defp handle_packet(%{phase: :status} = state, 1, <<token::64>>) do
    send_packets(state, [Packets.packet("pong_response", <<token::64>>, :status)])
    throw({:disconnect, :status_complete})
  end

  defp handle_packet(%{phase: :login, step: :hello} = state, 0, payload) do
    {name, <<_provided_uuid::binary-size(16)>>} = Wire.take_string(payload, 16)

    if not Regex.match?(~r/\A[A-Za-z0-9_]{1,16}\z/, name),
      do: reject(state, "Invalid player name")

    if state.encryption_requested do
      pair = Valimc.LoginKeys.pair()
      challenge = Encryption.challenge()
      send_packets(state, [Encryption.hello(pair, challenge, state.online_mode)])

      %{
        state
        | step: :key,
          login_name: name,
          key_pair: pair,
          key_public: pair.encoded,
          key_challenge: challenge
      }
    else
      LoginFlow.start_player_login(state, name)
    end
  end

  defp handle_packet(%{phase: :login, step: :key} = state, 1, payload) do
    if byte_size(payload) > 266, do: reject(state, "Invalid login encryption response")
    token = make_ref()

    case Valimc.KeyExchange.start(self(), token, state.key_pair, state.key_challenge, payload) do
      {:ok, job} ->
        timeout = max(job.deadline - System.monotonic_time(:millisecond), 0)
        job = Map.put(job, :timer, Process.send_after(self(), {:key_deadline, token}, timeout))
        Valimc.KeyExchange.activate(job)

        %{state | step: :key_job, key_job: job, key_pair: nil, key_challenge: nil}

      _ ->
        reject(state, "Server busy; please retry")
    end
  end

  defp handle_packet(%{phase: :login, step: :ack} = state, 3, <<>>) do
    state = %{state | phase: :configuration, step: :known_packs}
    send_packets(state, [Packets.known_packs()])
    state
  end

  defp handle_packet(%{phase: :configuration} = state, id, payload) do
    case {Data.name(:configuration, :serverbound, id), state.step} do
      {"select_known_packs", :known_packs} ->
        {count, payload} = Wire.take_varint(payload)
        if count != 1, do: reject(state, "The vanilla 26.3 core data pack is required")
        {namespace, payload} = Wire.take_string(payload)
        {pack_id, payload} = Wire.take_string(payload)
        {version, <<>>} = Wire.take_string(payload)

        if {namespace, pack_id, version} != {"minecraft", "core", Valimc.version()},
          do: reject(state, "The vanilla 26.3 core data pack is required")

        send_packets(state, Packets.configuration())
        %{state | step: :finish}

      {"finish_configuration", :finish} when payload == <<>> ->
        LoginFlow.enter_world(state)

      {name, _} when name in ["client_information", "custom_payload"] ->
        state

      _ ->
        reject(state, "Unexpected configuration packet")
    end
  end

  defp handle_packet(%{phase: :play} = state, id, payload) do
    case Data.name(:play, :serverbound, id) do
      name
      when state.life_stage != :alive and
             name in [
               "move_player_pos",
               "move_player_pos_rot",
               "move_player_rot",
               "move_player_status_only",
               "player_abilities",
               "player_input",
               "player_command",
               "player_action",
               "set_carried_item",
               "set_creative_mode_slot",
               "container_click",
               "container_close",
               "use_item",
               "use_item_on"
             ] ->
        state

      "client_command" ->
        case ClientCommand.decode(payload) do
          {:ok, :respawn} when state.life_stage in [:sealing_death, :dropping, :dead] ->
            Vitals.continue_life(%{state | respawn_requested: true})

          {:ok, _} ->
            state

          {:error, _} ->
            reject(state, "Invalid client lifecycle request")
        end

      "accept_teleportation" ->
        {id, <<x::float-64, y::float-64, z::float-64, _yaw::float-32, _pitch::float-32>>} =
          Wire.take_varint(payload)

        if id != state.teleport, do: reject(state, "Invalid teleport confirmation")

        if abs(x - state.player.x) + abs(y - state.player.y) + abs(z - state.player.z) > 0.01,
          do: reject(state, "Invalid teleport position")

        confirmed = state.teleport_pending
        resume = confirmed and state.login_velocity_pending

        state = %{
          state
          | teleport_pending: false,
            motion_window: nil,
            login_velocity_pending: false
        }

        if confirmed, do: send(self(), :send_chunks)
        if resume, do: Movement.send_velocity(state, state.player.motion.velocity), else: state

      "keep_alive" ->
        <<id::signed-64>> = payload

        case state.keepalive do
          {^id, _} -> %{state | keepalive: nil}
          _ -> reject(state, "Invalid keepalive")
        end

      "move_player_pos" ->
        <<x::float-64, y::float-64, z::float-64, flags>> = payload
        Movement.move(Movement.admit_position(state), %{x: x, y: y, z: z}, flags)

      "move_player_pos_rot" ->
        <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32, flags>> =
          payload

        Movement.move(
          Movement.admit_position(state),
          %{x: x, y: y, z: z, yaw: yaw, pitch: pitch},
          flags
        )

      "move_player_rot" ->
        <<yaw::float-32, pitch::float-32, flags>> = payload
        Movement.move(state, %{yaw: yaw, pitch: pitch}, flags)

      "move_player_status_only" ->
        <<flags>> = payload
        Movement.move(state, %{}, flags)

      "client_tick_end" ->
        <<>> = payload
        player = %{state.player | motion: PlayerMotion.finish_tick(state.player.motion)}
        Players.update(self(), player)
        %{state | client_tick: ClientTick.finish(state.client_tick), player: player}

      "chunk_batch_received" ->
        <<desired::float-32>> = payload
        if desired <= 0, do: reject(state, "Invalid chunk batch feedback")
        send(self(), :send_chunks)
        %{state | batch_pending: false}

      "player_abilities" ->
        {:ok, abilities} = PlayerAbilities.request_flight(state.player.abilities, payload)

        player = %{
          state.player
          | abilities: abilities,
            motion: PlayerMotion.flight(state.player.motion, abilities.flying)
        }

        Players.update(self(), player)
        %{state | player: player}

      "player_input" ->
        {:ok, input} = PlayerInput.receive_input(state.player.input, payload)
        Movement.update_player_input(state, input)

      "player_command" ->
        {:ok, input} = PlayerInput.receive_command(state.player.input, payload)
        Movement.update_player_input(state, input)

      "player_loaded" ->
        <<>> = payload
        Movement.update_player_input(state, PlayerInput.loaded(state.player.input))

      "change_game_mode" ->
        {_requested_id, <<>>} = Wire.take_varint(payload)
        # All current network sessions are unprivileged; operators are VMC-010.
        state

      "player_action" ->
        Mining.break_block(state, payload)

      "set_carried_item" ->
        <<slot::signed-16>> = payload

        case Inventory.select(state.inventory, slot) do
          {:ok, inventory} ->
            if Menus.selection_pending?(state) do
              send_packets(state, [Packets.held_slot(state.inventory.selected)])
              CreativeInventory.resync_inventory(state)
            else
              send_packets(state, [Packets.held_slot(slot)])

              state =
                if slot != state.inventory.selected and
                     match?(%PlayerUse{hand: :main}, state.active_use),
                   do: ItemUse.stop_item_use(state),
                   else: state

              %{state | inventory: inventory}
            end

          {:error, _} ->
            reject(state, "Invalid hotbar slot")
        end

      "set_creative_mode_slot" ->
        CreativeInventory.creative_slot(state, payload)

      "container_click" ->
        CreativeInventory.inventory_click(state, payload)

      "container_close" ->
        {_container, <<>>} = Wire.take_varint(payload)
        # Native close retires the current menu regardless of the supplied ID.
        if state.table_menu,
          do: Menus.begin_table_close(state),
          else: CreativeInventory.inventory_close(state)

      "use_item_on" ->
        Placement.place_block(state, payload)

      "use_item" ->
        ItemUse.use_item(state, payload)

      "chat" ->
        {message, _metadata} = Wire.take_string(payload, 256)
        state = Commands.throttle_chat(state)
        Players.broadcast({:chat, "<#{state.player.name}> #{message}"})
        state

      "chat_command" ->
        {command, <<>>} = Wire.take_string(payload, 256)
        state |> Commands.throttle_chat() |> Commands.command(command)

      nil ->
        reject(state, "Unknown packet ID")

      _known_but_unimplemented ->
        state
    end
  end

  defp handle_packet(state, _, _), do: reject(state, "Unexpected protocol state")

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

  def offline_uuid(name) do
    <<a::48, b::16, c::16, d::48>> = :crypto.hash(:md5, "OfflinePlayer:" <> name)
    <<a::48, (b &&& 0x0FFF) ||| 0x3000::16, (c &&& 0x3FFF) ||| 0x8000::16, d::48>>
  end

  @impl true
  def terminate(_reason, state) do
    Menus.retire_container_view(state)
    Menus.cancel_table_query(state)
    Transfers.cancel_pickup_query(state)
    Transfers.cancel_experience_query(state)
    Mining.cancel_mining(state)

    :gen_tcp.close(state.socket)

    if state.motion_pending && state.motion_pending.retry,
      do: Process.cancel_timer(state.motion_pending.retry)

    Jobs.cancel_all(state.jobs)

    if state.key_job do
      Process.cancel_timer(state.key_job.timer)
      Process.demonitor(state.key_job.monitor, [:flush])

      Valimc.KeyExchange.cancel(state.key_job)
    end

    if state.auth_job do
      Process.cancel_timer(state.auth_job.timer)
      Process.demonitor(state.auth_job.monitor, [:flush])
      Valimc.Auth.SessionJobs.cancel(state.auth_job)
    end

    if state.recovery do
      Process.cancel_timer(state.recovery.timer)
      if state.recovery.retry_timer, do: Process.cancel_timer(state.recovery.retry_timer)

      if state.recovery.job && Process.whereis(Valimc.TransferWorkers) != nil,
        do: Task.Supervisor.terminate_child(Valimc.TransferWorkers, state.recovery.job.pid)
    end

    if state.player_store && state.phase == :play do
      # Observations can lag quiet simulation clocks. Persist the owner state;
      # per-frame exception boundaries already retain earlier accepted packets.
      snapshot =
        case state.life_save do
          %{kind: :respawn, snapshot: snapshot} ->
            snapshot

          _ ->
            PlayerSnapshot.capture(state.player, state.inventory)
        end

      try do
        PlayerStore.close_session(
          state.player_store,
          state.store_fence,
          snapshot
        )
      catch
        :exit, _ ->
          Logger.error("Player state final save could not complete")
      end
    end
  end
end
