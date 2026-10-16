defmodule Valimc.Connection do
  use GenServer, restart: :temporary, shutdown: 15_000

  @moduledoc "A socket-owning process per player, including their protocol and connection-local state."
  alias Valimc.Protocol.{
    ClientCommand,
    ClientTick,
    Data,
    Encryption,
    InventoryClick,
    ItemStack,
    ItemTypes,
    Packets,
    UseItem,
    UseItemOn,
    Wire
  }

  alias Valimc.{
    CreativeInput,
    FoodItems,
    GameMode,
    Inventory,
    Metrics,
    Players,
    PlayerAbilities,
    PlayerEnvironment,
    PlayerEquipment,
    PlayerFood,
    PlayerHealth,
    PlayerInput,
    PlayerKinetics,
    PlayerLife,
    PlayerMotion,
    PlayerMotionQuery,
    PlayerMining,
    PlayerMiningAttempt,
    PlayerMiningQuery,
    PlayerPlacementQuery,
    PlayerPoseQuery,
    PlayerSnapshot,
    PlayerStore,
    PlayerTransfers,
    PlayerUse,
    TransferDelivery,
    World
  }

  alias Valimc.World.TickClock

  alias Valimc.World.{ItemReplication, WeatherReplication}
  import Bitwise
  @basic_mining Enum.map(~w(stone dirt grass_block cobblestone oak_planks glass), &Data.block/1)
  @slab_tags Path.expand("../../priv/protocol/tags.json", __DIR__)
  @external_resource @slab_tags
  @slab_blocks :json.decode(File.read!(@slab_tags))["minecraft:block"]["minecraft:slabs"]
               |> MapSet.new()

  defguardp inventory_pending(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   (state.placement_job != nil and state.placement_job.command.mode == :survival)

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
      {:reply, :ok, relocate(state, Map.merge(state.player, destination))}
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
      state = state |> cancel_pose_job() |> cancel_motion_job()
      velocity = velocity |> Tuple.to_list() |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()
      motion = %{state.player.motion | velocity: velocity, settled: false}
      player = %{state.player | motion: motion}
      Players.update(self(), player)
      state = %{state | player: player, pose_checked: nil, login_velocity_pending: false}
      state = send_velocity(state, velocity)
      {:reply, :ok, state |> start_motion() |> sample_pose()}
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
            {result, next} = apply_damage(state, selected, :fall)
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

  def deliver(pid, event) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, size} ->
        if size <= Valimc.config(:max_mailbox) do
          send(pid, {:event, event})
          :ok
        else
          Metrics.add(:slow_clients_disconnected)
          Process.exit(pid, :kill)
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
       player_store: nil,
       store_fence: nil,
       store_monitor: nil,
       save_ref: nil,
       use_save: nil,
       active_use: nil,
       mining: nil,
       mining_job: nil,
       mining_water: false,
       placement_queue: :queue.new(),
       placement_queued: 0,
       placement_job: nil,
       life_save: nil,
       life_stage: :alive,
       respawn_requested: false,
       recovery: nil,
       creative_input: CreativeInput.new(creative_tick()),
       creative_drain_scheduled: false,
       chunks: MapSet.new(),
       regions: MapSet.new(),
       pending: [],
       batch_pending: false,
       peers: %{},
       player_flags_view: 0,
       equipment_source: nil,
       pose_job: nil,
       pose_checked: nil,
       pose_generation: 0,
       pose_sources: %{},
       motion_job: nil,
       motion_pending: nil,
       motion_window: nil,
       simulation_clock: nil,
       food_tick_origin: 0,
       simulation_due: false,
       item_replication: ItemReplication.new(),
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
  def handle_info(:activate, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    Process.send_after(self(), :login_deadline, Valimc.config(:login_timeout_ms))
    Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))
    Metrics.add(:connections_accepted)
    {:noreply, %{state | active: true}}
  end

  def handle_info({:tcp, socket, data}, %{socket: socket} = state) do
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

  def handle_info(:drain, state), do: guard_connection(state, fn -> consume(state, 64) end)
  def handle_info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def handle_info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def handle_info(
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
            state = start_player_login(%{state | key_public: nil}, state.login_name)
            consume(state, 64)
          end

        _ ->
          reject(state, "Invalid login encryption response")
      end
    end)
  end

  def handle_info({:key_verified, _, _, _}, state), do: {:noreply, state}

  def handle_info(
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

          state = start_player_login(%{state | step: nil}, state.login_name, profile)
          consume(state, 64)

        {:error, :unverified_session} ->
          reject(state, "Failed to verify username")

        _ ->
          reject(state, "Authentication servers unavailable; please retry")
      end
    end)
  end

  def handle_info({:session_verified, _, _, _}, state), do: {:noreply, state}

  def handle_info({:session_deadline, token}, %{auth_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do: guard_connection(state, fn -> reject(state, "Authentication timed out") end),
      else: {:noreply, state}
  end

  def handle_info({:session_deadline, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{auth_job: %{monitor: ref}} = state),
    do:
      guard_connection(state, fn ->
        reject(state, "Authentication servers unavailable; please retry")
      end)

  def handle_info({:key_deadline, token}, %{key_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do: guard_connection(state, fn -> reject(state, "Login encryption timed out") end),
      else: {:noreply, state}
  end

  def handle_info({:key_deadline, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{key_job: %{monitor: ref}} = state),
    do: guard_connection(state, fn -> reject(state, "Login encryption unavailable") end)

  def handle_info(:save_player, state) do
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

  def handle_info({:player_saved, ref, :ok}, %{life_save: %{ref: ref} = save} = state) do
    guard_connection(state, fn ->
      state = %{state | life_save: if(save.kind == :respawn, do: save, else: nil), save_ref: nil}

      state =
        case save.kind do
          :death_mark ->
            continue_life(%{state | life_stage: :dropping})

          :death_done ->
            state = %{
              state
              | inventory: recovered_inventory(state, save.snapshot),
                life_stage: :dead
            }

            if state.phase == :login, do: finish_login(state), else: continue_life(state)

          :respawn ->
            finish_respawn(state, save.player)
        end

      {:noreply, state}
    end)
  end

  def handle_info({:player_saved, ref, :ok}, %{save_ref: ref} = state),
    do:
      guard_connection(state, fn ->
        {:noreply,
         %{state | save_ref: nil, use_save: nil}
         |> drain_creative()
         |> continue_life()
         |> drain_placements()}
      end)

  def handle_info(:drain_creative, %{creative_drain_scheduled: true} = state),
    do:
      guard_connection(state, fn ->
        {:noreply,
         state
         |> Map.put(:creative_drain_scheduled, false)
         |> drain_creative()
         |> sync_creative_result()}
      end)

  def handle_info(:drain_creative, state), do: {:noreply, state}

  def handle_info({:player_saved, ref, {:error, _}}, %{save_ref: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player save failed") end)

  def handle_info({:save_deadline, ref}, %{save_ref: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player save timed out") end)

  def handle_info({:save_deadline, _}, state), do: {:noreply, state}

  def handle_info(
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
        {:noreply, recovery_failure(state, result)}
      end
    end)
  end

  def handle_info({:transfer_delivered, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:player_transfer_saved, ref, {:ok, fence, snapshot}},
        %{recovery: %{stage: :prepare, ref: ref, plan: plan} = recovery} = state
      ) do
    guard_connection(state, fn ->
      expected_outbox = Map.get(plan, :intent, %{key: plan.key, records: plan.records})

      if snapshot.outbox != expected_outbox or
           snapshot.inventory.slots != plan.inventory.slots or
           snapshot.inventory.carried != plan.inventory.carried or
           snapshot.inventory.selected != plan.inventory.selected,
         do: reject(state, "Inventory transfer returned inconsistent state")

      recovery = %{
        recovery
        | stage: :delivery,
          intent: Map.take(snapshot, [:outbox, :transfer_sequence]),
          ref: nil
      }

      state = %{state | recovery: recovery, store_fence: fence}
      state = %{state | inventory: recovered_inventory(state, snapshot)}

      state =
        if recovery.mode == :login or state.life_stage != :alive or creative_pending?(state),
          do: state,
          else: resync_inventory(state)

      {:noreply, deliver_recovery(state)}
    end)
  end

  def handle_info(
        {:player_transfer_saved, ref, {:error, reason}},
        %{recovery: %{stage: :prepare, ref: ref} = recovery} = state
      ) do
    guard_connection(state, fn ->
      if reason == :player_commit_uncertain,
        do: reject(state, "Inventory transfer commit is uncertain; reconnect to recover")

      if recovery.mode == :death,
        do: reject(state, "Death inventory cleanup could not be committed; reconnect to recover")

      if recovery.mode == :login,
        do:
          reject(
            state,
            "Disconnected inventory cleanup could not be prepared; please retry later"
          )

      Process.cancel_timer(recovery.timer)

      send_packets(state, [
        Packets.chat("Item operation could not be prepared; inventory restored")
      ])

      {:noreply,
       state
       |> Map.put(:recovery, nil)
       |> correct_block_recovery(recovery)
       |> drain_creative()
       |> sync_creative_result()
       |> continue_life()
       |> drain_placements()}
    end)
  end

  def handle_info(
        {:player_transfer_saved, ref, {:ok, fence, snapshot}},
        %{recovery: %{stage: :complete, ref: ref} = recovery} = state
      ) do
    guard_connection(state, fn ->
      if snapshot.outbox != nil or snapshot.transfer_sequence != recovery.intent.transfer_sequence,
        do: reject(state, "Inventory recovery returned inconsistent state")

      Process.cancel_timer(recovery.timer)
      inventory = recovered_inventory(state, snapshot)
      state = %{state | recovery: nil, store_fence: fence, inventory: inventory}
      state = correct_block_recovery(state, recovery)

      {:noreply,
       if(recovery.mode == :login,
         do: reconcile_login(state),
         else:
           state
           |> drain_creative()
           |> sync_creative_result()
           |> continue_life()
           |> drain_placements()
       )}
    end)
  end

  def handle_info(
        {:player_transfer_saved, ref, {:error, _} = error},
        %{recovery: %{stage: :complete, ref: ref}} = state
      ),
      do: guard_connection(state, fn -> {:noreply, recovery_failure(state, error)} end)

  def handle_info({:player_transfer_saved, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:retry_recovery, id, token},
        %{recovery: %{id: id, stage: :retry, retry_token: token} = recovery} = state
      ) do
    state = %{state | recovery: %{recovery | retry_timer: nil}}
    guard_connection(state, fn -> {:noreply, deliver_recovery(state)} end)
  end

  def handle_info({:retry_recovery, _, _}, state), do: {:noreply, state}

  def handle_info({:recovery_deadline, id}, %{recovery: %{id: id}} = state),
    do:
      guard_connection(state, fn ->
        reject(state, "Inventory recovery is still pending; please retry later")
      end)

  def handle_info({:recovery_deadline, _}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, worker, _},
        %{recovery: %{stage: :delivery, job: %{pid: worker, monitor: monitor}} = recovery} = state
      ) do
    state = %{state | recovery: %{recovery | job: nil}}

    guard_connection(state, fn ->
      {:noreply, recovery_failure(state, {:error, :region_restarting})}
    end)
  end

  def handle_info({ref, result}, %{placement_job: %{task: %Task{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(job.timer)

    guard_connection(state, fn ->
      case result do
        {:reserved, reservation} ->
          state = %{state | placement_job: nil}
          {:noreply, prepare_survival_placement(state, job.command, reservation)}

        {:ok, _outcome} ->
          state = if job.command.body == nil, do: resync_inventory(state), else: state
          send_packets(state, [Packets.ack(job.command.request.sequence)])
          {:noreply, %{state | placement_job: nil} |> continue_life() |> drain_placements()}

        _ ->
          reject(state, "Block interaction unavailable; please reconnect")
      end
    end)
  end

  def handle_info({:placement_deadline, ref}, %{placement_job: %{task: %Task{ref: ref}}} = state),
    do:
      guard_connection(state, fn ->
        reject(state, "Block interaction timed out; please reconnect")
      end)

  def handle_info({:placement_deadline, _}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{placement_job: %{task: %Task{ref: ref}}} = state
      ),
      do:
        guard_connection(state, fn ->
          reject(state, "Block interaction failed; please reconnect")
        end)

  def handle_info({ref, result}, %{mining_job: %{task: %Task{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(job.timer)

    guard_connection(state, fn ->
      state = %{state | mining_job: nil}

      if System.monotonic_time(:millisecond) < job.deadline do
        {:noreply, mining_result(state, job, result)}
      else
        if job.kind == :reserve and match?({:ok, %{owner: _, permit: _}}, result),
          do: PlayerMiningQuery.release(elem(result, 1))

        state = cancel_mining(state)
        {:noreply, if(job.kind == :correct, do: state, else: correct_mining(state, job.position))}
      end
    end)
  end

  def handle_info({:mining_deadline, ref}, %{mining_job: %{task: %Task{ref: ref}}} = state),
    do: guard_connection(state, fn -> {:noreply, cancel_mining(state)} end)

  def handle_info({:mining_deadline, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{mining_job: %{task: %Task{ref: ref}}} = state),
    do: guard_connection(state, fn -> {:noreply, cancel_mining(state)} end)

  def handle_info({ref, result}, %{motion_job: %{task: %Task{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(job.timer)

    guard_connection(state, fn ->
      state = %{state | motion_job: nil}

      cond do
        System.monotonic_time(:millisecond) >= job.input.deadline ->
          {:noreply, correct_motion(state, :movement_late_result_corrections)}

        motion_signature(state) != job.signature ->
          {:noreply, start_motion(state)}

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
                  |> apply_movement_exhaustion(exhaustion)
                  |> apply_kinetic_tick(kinetics.tick, kinetics.packet.bounced)
                  |> observe_environment(powder, submerged, eye_water)
                  |> monitor_pose_sources(fences)
                  |> update_view()
                  |> apply_landing(landing)

                {:noreply,
                 if(next.life_stage == :alive,
                   do: %{next | pose_checked: pose_signature(next)},
                   else: next
                 )}
              else
                {:noreply, correct_motion(state, :movement_source_corrections)}
              end

            {:ok, %{accepted: false}} ->
              {:noreply, correct_motion(state, :movement_collision_corrections)}

            {:error, reason} ->
              metric =
                if reason == :collision_query_timeout,
                  do: :movement_query_timeout_corrections,
                  else: :movement_geometry_corrections

              {:noreply, correct_motion(state, metric)}
          end
      end
    end)
  end

  def handle_info({:motion_deadline, ref}, %{motion_job: %{task: %Task{ref: ref}}} = state),
    do:
      guard_connection(state, fn ->
        {:noreply, correct_motion(state, :movement_worker_deadline_corrections)}
      end)

  def handle_info({:motion_deadline, _}, state), do: {:noreply, state}

  def handle_info({:retry_motion, token}, %{motion_pending: %{token: token} = input} = state),
    do:
      guard_connection(state, fn ->
        {:noreply, start_motion(%{state | motion_pending: %{input | retry: nil}})}
      end)

  def handle_info({:retry_motion, _}, state), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{motion_job: %{task: %Task{ref: ref}}} = state),
    do:
      guard_connection(state, fn ->
        {:noreply, correct_motion(state, :movement_geometry_corrections)}
      end)

  def handle_info({ref, result}, %{pose_job: %{task: %Task{ref: ref}} = job} = state) do
    Process.demonitor(ref, [:flush])

    guard_connection(state, fn ->
      state = %{state | pose_job: nil}

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
               pose_signature(state) == job.signature and
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
              |> apply_kinetic_tick(kinetics, false)
              |> observe_environment(powder, submerged, eye_water)
              |> monitor_pose_sources(fences)

            state =
              if state.life_stage == :alive,
                do: %{state | pose_checked: pose_signature(state)},
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

  def handle_info({:DOWN, ref, :process, _, _}, %{pose_job: %{task: %Task{ref: ref}}} = state),
    do: {:noreply, %{state | pose_job: nil}}

  # Cancelling geometry retires its reference; a result already in this mailbox
  # must never become a new player input or crash a healthy connection.
  def handle_info({ref, _}, state) when is_reference(ref), do: {:noreply, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{store_monitor: ref} = state),
    do: guard_connection(state, fn -> reject(state, "Player storage stopped") end)

  def handle_info({:DOWN, ref, :process, _, _}, state) do
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

  def handle_info(:login_deadline, %{phase: :play} = state), do: {:noreply, state}
  def handle_info(:login_deadline, state), do: {:stop, :normal, state}

  def handle_info(:keepalive, state) do
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

  def handle_info(
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
            do: broadcast_player_packet(state, Packets.remove_entity(player))

          state = %{state | player: player, simulation_clock: next, simulation_due: true}

          {:noreply,
           state
           |> apply_void_damage()
           |> tick_item_use()
           |> tick_food()
           |> tick_mining()
           |> start_motion()
           |> sample_pose()}

        {:early, next, delay} ->
          Process.send_after(self(), {:player_tick, next.token}, delay)
          {:noreply, %{state | simulation_clock: next}}

        :stale ->
          {:noreply, state}
      end
    end)
  end

  def handle_info({:player_tick, _}, state), do: {:noreply, state}

  def handle_info(:publish_movement, state) do
    guard_connection(state, fn ->
      if state.phase == :play do
        Process.send_after(self(), :publish_movement, 50)

        state =
          update_player_input(publish_equipment(state), PlayerInput.tick(state.player.input))
          |> start_motion()
          |> sample_pose()

        state =
          if state.player_flags_view != Packets.shared_flags(state.player) do
            state = emit_peer_packets(state, [Packets.player_flags(state.player)], :buffer)
            %{state | player_flags_view: Packets.shared_flags(state.player)}
          else
            state
          end

        nearby = Players.nearby(state.regions)

        state =
          Enum.reduce(nearby, state, fn pid, acc ->
            case Players.get(pid) do
              {:ok, player} -> track_peer(acc, player, :buffer)
              :error -> acc
            end
          end)

        state =
          Enum.reduce(state.peers, state, fn {pid, player}, acc ->
            if MapSet.member?(nearby, pid),
              do: acc,
              else: %{
                emit_peer_packets(
                  acc,
                  [Packets.remove_entity(player), Packets.remove_info(player)],
                  :buffer
                )
                | peers: Map.delete(acc.peers, pid)
              }
          end)

        desired_items = World.visible_items(state.regions, state.chunks)

        {item_replication, item_packets} =
          ItemReplication.reconcile(state.item_replication, desired_items)

        state =
          emit_peer_packets(%{state | item_replication: item_replication}, item_packets, :buffer)

        {version, clock_packet} = Valimc.World.Clock.publication()

        state =
          if version != state.clock_version do
            %{state | clock_version: version, outbound: [clock_packet | state.outbound]}
          else
            state
          end

        {weather_view, weather_packets} =
          WeatherReplication.reconcile(state.weather_view, Valimc.World.Clock.weather())

        state = emit_peer_packets(%{state | weather_view: weather_view}, weather_packets, :buffer)

        {difficulty, difficulty_packet} = Valimc.World.Clock.difficulty()

        state =
          if state.difficulty_view != difficulty,
            do:
              emit_peer_packets(
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

  def handle_info(:send_chunks, state),
    do: guard_connection(state, fn -> {:noreply, stream_chunks(state)} end)

  def handle_info({:event, event}, state) do
    guard_connection(state, fn -> {:noreply, event(state, event)} end)
  end

  defp guard_connection(state, work) do
    work.()
  rescue
    _ ->
      Metrics.add(:malformed_connections)
      {:stop, :normal, state}
  catch
    {:disconnect, _reason, current} -> {:stop, :normal, current}
    {:disconnect, _reason} -> {:stop, :normal, state}
  end

  defp reset_window(state) do
    now = System.monotonic_time(:second)

    if now == state.window,
      do: state,
      else: %{state | window: now, packets: 0, bytes: 0, logical_bytes: 0}
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

  defp finish_login(state) do
    threshold = Valimc.config(:compression_threshold)

    if threshold != nil,
      do:
        send_packets(state, [Packets.packet("login_compression", Wire.varint(threshold), :login)])

    state = %{state | threshold: threshold, step: :ack}

    send_packets(state, [
      Packets.packet(
        "login_finished",
        [
          state.player.uuid,
          Wire.string(state.player.name),
          Packets.properties(state.player.properties),
          :crypto.strong_rand_bytes(16)
        ],
        :login
      )
    ])

    state
  end

  defp reconcile_login(state) do
    before = PlayerSnapshot.capture(state.player, state.inventory)
    {:ok, after_snapshot, key, records} = PlayerTransfers.plan_cleanup(before)

    if records == [] do
      state = %{state | inventory: recovered_inventory(state, after_snapshot)}

      if state.player.health.value <= 0,
        do: checkpoint_life(state, :death_done, after_snapshot),
        else: finish_login(state)
    else
      ref = make_ref()

      recovery = %{
        new_recovery(:login, :prepare, nil)
        | ref: ref,
          plan: %{key: key, records: records, inventory: after_snapshot.inventory}
      }

      prepare =
        if state.player.health.value <= 0,
          do: &PlayerStore.prepare_death/7,
          else: &PlayerStore.prepare_transfer/7

      prepare.(
        state.player_store,
        state.store_fence,
        before,
        after_snapshot,
        key,
        records,
        ref
      )

      %{state | step: :recover, recovery: recovery}
    end
  end

  defp deliver_recovery(state) do
    token = make_ref()

    case TransferDelivery.start(self(), token, state.player.uuid, state.recovery.intent) do
      {:ok, job} -> %{state | recovery: %{state.recovery | stage: :delivery, job: job}}
      error -> recovery_failure(state, error)
    end
  end

  defp recovered_inventory(state, snapshot) do
    %{
      snapshot.inventory
      | infinite_materials: state.inventory.infinite_materials,
        state_id: state.inventory.state_id,
        drag: nil
    }
  end

  defp apply_landing(state, nil), do: state

  defp apply_landing(state, call) do
    {:ok, amount} =
      Valimc.Physics.FallDamage.calculate(
        call.distance,
        call.multiplier,
        %Valimc.Physics.FallDamage{}
      )

    if amount > 0 do
      {:ok, selected} = PlayerHealth.hurt_window(state.player.health, amount)
      {_, state} = apply_damage(state, selected, call.source)
      state
    else
      state
    end
  end

  defp apply_void_damage(%{life_stage: :alive} = state) do
    amount = Valimc.PlayerVoid.damage(state.player.y, Valimc.World.Chunk.min_y())

    if amount > 0 do
      {:ok, selected} = PlayerHealth.hurt_window(state.player.health, amount)
      {_, state} = apply_damage(state, selected, :out_of_world)
      state
    else
      state
    end
  end

  defp apply_void_damage(state), do: state

  defp use_item(state, payload) do
    case UseItem.decode(payload) do
      {:ok, request} ->
        if PlayerInput.loaded?(state.player.input) do
          send_packets(state, [Packets.ack(request.sequence)])
          # Native requests supply wrapped viewing angles before attempting use.
          player = %{
            state.player
            | yaw: wrap_angle(request.yaw),
              pitch: wrap_angle(request.pitch)
          }

          Players.update(self(), player)
          begin_item_use(%{state | player: player}, request.hand)
        else
          state
        end

      {:error, _} ->
        reject(state, "Invalid item use request")
    end
  end

  defp wrap_angle(value) do
    value = :math.fmod(value, 360.0)

    cond do
      value >= 180.0 -> value - 360.0
      value < -180.0 -> value + 360.0
      true -> value
    end
  end

  defp begin_item_use(state, _) when inventory_pending(state), do: resync_inventory(state)
  defp begin_item_use(%{active_use: %PlayerUse{}} = state, _), do: state
  defp begin_item_use(%{player: %{game_mode: %{current: :spectator}}} = state, _), do: state

  defp begin_item_use(state, hand) do
    state = publish_equipment(state)
    stack = Inventory.held(state.inventory, hand)
    props = if stack, do: FoodItems.properties(stack)

    if props && FoodItems.plain?(props) &&
         FoodItems.eligible?(props, state.player.food, state.player.abilities) do
      use = PlayerUse.new(stack, hand, props)
      state = %{state | active_use: use}

      if use.remaining == 0,
        do: complete_item_use(state, false),
        else: publish_item_use(state, PlayerUse.start_flags(state.player.use_flags, hand))
    else
      resync_inventory(state)
    end
  end

  defp publish_item_use(state, flags) do
    player = %{state.player | use_flags: flags}
    Players.update(self(), player)
    state = %{state | player: player}
    packet = Packets.player_use(player)
    send_packets(state, [packet])

    for pid <- Players.nearby(state.regions),
        pid != self(),
        do: deliver(pid, {:player_use_packet, self(), player.entity_id, packet})

    state
  end

  defp publish_equipment(state) do
    source = {state.inventory.selected, state.inventory.slots}

    if source == state.equipment_source do
      state
    else
      equipment = PlayerEquipment.capture(state.inventory)

      if PlayerEquipment.changes(equipment, state.player.equipment) == [] do
        %{state | equipment_source: source}
      else
        player = %{state.player | equipment: equipment}
        Players.update(self(), player)
        %{state | player: player, equipment_source: source}
      end
    end
  end

  defp stop_item_use(%{active_use: nil} = state), do: state

  defp stop_item_use(state),
    do: publish_item_use(%{state | active_use: nil}, PlayerUse.stop_flags(state.player.use_flags))

  defp tick_item_use(%{life_stage: :alive, active_use: %PlayerUse{} = use} = state) do
    case PlayerUse.tick(use, Inventory.held(state.inventory, use.hand)) do
      {:using, next} -> %{state | active_use: next}
      {:finish, next} -> complete_item_use(%{state | active_use: next}, true)
      {:cancel, _} -> stop_item_use(state)
    end
  end

  defp tick_item_use(state), do: state

  defp complete_item_use(state, _) when inventory_pending(state) or state.save_ref != nil,
    do: state

  defp complete_item_use(state, notify) do
    use = state.active_use
    stack = Inventory.held(state.inventory, use.hand)
    props = FoodItems.properties(stack)

    if FoodItems.plain?(props) do
      case Inventory.consume_hand(state.inventory, use.hand, props.remainder) do
        {:ok, inventory, []} ->
          food =
            if props.food,
              do: PlayerFood.eat(state.player.food, props.food.nutrition, props.food.saturation),
              else: state.player.food

          player = %{state.player | food: food}
          # One atomic checkpoint owns both changes. No world item escapes this lane.
          ref = make_ref()

          PlayerStore.checkpoint(
            state.player_store,
            state.store_fence,
            PlayerSnapshot.capture(player, inventory),
            ref
          )

          Process.send_after(self(), {:save_deadline, ref}, 5000)
          state = %{state | player: player, inventory: inventory, save_ref: ref, use_save: ref}
          Players.update(self(), player)
          if notify, do: send_packets(state, [Packets.use_item_finished(player.entity_id)])
          state = state |> publish_equipment() |> stop_item_use()

          send_packets(state, [
            Packets.health(player.health, food),
            Packets.inventory(inventory),
            Packets.cursor(inventory.carried)
          ])

          state

        _ ->
          # Patched stackable containers need an explicit conversion outbox before
          # overflowing into the world. Reject the whole meal until that exists.
          state |> stop_item_use() |> resync_inventory()
      end
    else
      state |> stop_item_use() |> resync_inventory()
    end
  end

  defp apply_movement_exhaustion(%{player: %{abilities: %{invulnerable: true}}} = state, _),
    do: state

  defp apply_movement_exhaustion(state, %{jump: jump, travel: travel})
       when jump == 0 and travel == 0,
       do: state

  defp apply_movement_exhaustion(state, %{jump: jump, travel: travel}) do
    food = state.player.food |> PlayerFood.exhaust(jump) |> PlayerFood.exhaust(travel)
    player = %{state.player | food: food}
    if food != state.player.food, do: Players.update(self(), player)
    %{state | player: player}
  end

  defp tick_food(%{life_stage: :alive} = state) do
    phase = rem(state.simulation_clock.tick - state.food_tick_origin, 20)

    if PlayerFood.idle?(state.player.food, state.player.health, phase),
      do: state,
      else: advance_food(state, phase)
  end

  defp tick_food(state), do: state

  defp advance_food(state, phase) do
    {difficulty, regeneration} = World.Clock.survival()
    before = state.player

    {food, peaceful_heal} =
      PlayerFood.peaceful(before.food, before.health, difficulty, regeneration, phase)

    health = heal(before.health, peaceful_heal)
    {food, effect} = PlayerFood.tick(food, health, difficulty, regeneration)
    health = heal(health, effect.heal)

    state =
      if before.food != food or before.health != health do
        player = %{before | food: food, health: health}
        Players.update(self(), player)
        %{state | player: player}
      else
        state
      end

    # Native replication observes health, food and whether saturation crossed zero.
    if before.health.value != health.value or before.food.level != food.level or
         before.food.saturation == 0 != (food.saturation == 0),
       do: send_packets(state, [Packets.health(health, food)])

    if before.health.value != health.value do
      packet = Packets.player_health(state.player)
      send_packets(state, [packet])
      broadcast_player_packet(state, packet)
    end

    if effect.damage > 0 do
      {:ok, selected} = PlayerHealth.hurt_window(health, effect.damage)
      {_, state} = apply_damage(state, selected, :starve)
      state
    else
      state
    end
  end

  defp heal(health, amount) do
    if health.value > 0 and amount > 0 do
      {:ok, next} = PlayerHealth.set(health, health.value + amount)
      next
    else
      health
    end
  end

  defp apply_damage(state, selected, source) do
    cond do
      state.life_stage != :alive or not selected.accepted ->
        {:ignored, state}

      (source in [:fall, :stalagmite] and state.player.abilities.may_fly) or
        (source != :out_of_world and state.player.abilities.invulnerable) or
          not PlayerInput.loaded?(state.player.input) ->
        {:immune, state}

      true ->
        {:ok, damage} =
          Valimc.PlayerDamageProtection.damage(state.inventory, source, selected.damage)

        {:ok, health} = PlayerHealth.reduce(selected.state, damage)
        player = %{state.player | health: health}
        state = %{state | player: player}

        state =
          if health.value <= 0 do
            state =
              state
              |> cancel_pose_job()
              |> cancel_motion_job()
              |> stop_item_use()
              |> cancel_mining()

            player = PlayerLife.die(%{player | use_flags: state.player.use_flags})

            %{
              state
              | player: player,
                motion_pending: nil,
                motion_window: nil,
                pose_checked: nil,
                pose_generation: state.pose_generation + 1,
                life_stage: :sealing_death,
                creative_input: CreativeInput.clear(state.creative_input)
            }
          else
            state
          end

        Players.update(self(), state.player)

        if selected.notify do
          packet = Packets.damage_event(state.player.entity_id, source)
          send_packets(state, [packet])
          broadcast_player_packet(state, packet)
        end

        send_packets(state, [
          Packets.health(state.player.health, state.player.food),
          Packets.player_health(state.player)
        ])

        state = if health.value <= 0, do: death_notice(state, true, source), else: state
        send(self(), :drain)
        {if(health.value <= 0, do: :dead, else: :hurt), continue_life(state)}
    end
  end

  defp death_notice(state, announce, source \\ :fall) do
    reason =
      cond do
        not announce -> " died"
        source == :freeze -> " froze to death"
        source == :drown -> " drowned"
        source == :out_of_world -> " fell out of the world"
        source == :starve -> " starved to death"
        source == :stalagmite -> " was impaled on a stalagmite"
        true -> " hit the ground too hard"
      end

    message = state.player.name <> reason

    send_packets(state, [
      Packets.player_pose(state.player),
      Packets.death(state.player.entity_id, message),
      Packets.death_animation(state.player.entity_id)
    ])

    broadcast_player_packet(state, Packets.death_animation(state.player.entity_id))
    if announce, do: Players.broadcast({:chat, message})
    state
  end

  defp checkpoint_life(state, kind, snapshot, player \\ nil) do
    ref = make_ref()
    PlayerStore.checkpoint(state.player_store, state.store_fence, snapshot, ref)
    Process.send_after(self(), {:save_deadline, ref}, 5000)

    %{
      state
      | save_ref: ref,
        life_save: %{kind: kind, ref: ref, snapshot: snapshot, player: player}
    }
  end

  defp continue_life(%{save_ref: ref} = state) when ref != nil, do: state
  defp continue_life(%{recovery: recovery} = state) when recovery != nil, do: state

  defp continue_life(%{life_stage: :sealing_death, phase: :play} = state),
    do: checkpoint_life(state, :death_mark, PlayerSnapshot.capture(state.player, state.inventory))

  defp continue_life(%{life_stage: :dropping, phase: :play} = state) do
    before = PlayerSnapshot.capture(state.player, state.inventory)
    {:ok, after_snapshot, key, records} = PlayerTransfers.plan_death(before)

    if records == [] do
      checkpoint_life(state, :death_done, after_snapshot)
    else
      ref = make_ref()

      recovery = %{
        new_recovery(:death, :prepare, nil)
        | ref: ref,
          plan: %{key: key, records: records, inventory: after_snapshot.inventory}
      }

      PlayerStore.prepare_death(
        state.player_store,
        state.store_fence,
        before,
        after_snapshot,
        key,
        records,
        ref
      )

      %{state | recovery: recovery}
    end
  end

  defp continue_life(%{life_stage: :dead, respawn_requested: true} = state) do
    player = PlayerLife.respawn(state.player)
    snapshot = PlayerSnapshot.capture(player, Inventory.new(player.abilities.infinite_materials))
    checkpoint_life(%{state | life_stage: :respawning}, :respawn, snapshot, player)
  end

  defp continue_life(state), do: state

  defp finish_respawn(state, player) do
    old_entities = Enum.map(state.peers, fn {_, view} -> Packets.remove_entity(view) end)
    old_items = Map.keys(state.item_replication.tracked)

    old_items =
      if old_items == [], do: [], else: [Valimc.Protocol.EntityPackets.remove(old_items)]

    send_packets(state, Enum.map(state.chunks, &Packets.unload/1) ++ old_entities ++ old_items)
    {clock_version, clock_packet} = Valimc.World.Clock.initial()
    {difficulty, difficulty_packet} = Valimc.World.Clock.difficulty()

    {weather_view, weather_packets} =
      WeatherReplication.reconcile(nil, Valimc.World.Clock.weather())

    inventory = Inventory.new(player.abilities.infinite_materials)

    state = %{
      state
      | player: player,
        inventory: inventory,
        life_stage: :alive,
        active_use: nil,
        respawn_requested: false,
        food_tick_origin: state.simulation_clock.tick,
        client_tick: %ClientTick{},
        center: nil,
        chunks: MapSet.new(),
        pending: [],
        batch_pending: false,
        peers: %{},
        item_replication: ItemReplication.new(),
        clock_version: clock_version,
        difficulty_view: difficulty,
        weather_view: weather_view
    }

    send_packets(
      state,
      [
        Packets.respawn(player, player.last_death),
        Packets.level_load_start(),
        clock_packet,
        difficulty_packet,
        Packets.abilities(player.abilities),
        Packets.health(player.health, player.food),
        Packets.player_health(player),
        Packets.player_use(player),
        Packets.player_pose(player),
        Packets.player_environment(player),
        Packets.spawn_position(),
        Packets.interaction_attributes(player),
        Packets.inventory(inventory),
        Packets.cursor(nil),
        Packets.held_slot(0)
      ] ++ weather_packets
    )

    state = relocate(state, player)

    for pid <- Players.nearby(state.regions),
        pid != self(),
        do: deliver(pid, {:player_respawned, self(), player.entity_id})

    %{state | life_save: nil}
  end

  defp new_recovery(mode, stage, intent) do
    id = make_ref()

    %{
      id: id,
      mode: mode,
      stage: stage,
      intent: intent,
      plan: nil,
      job: nil,
      ref: nil,
      retry_timer: nil,
      retry_token: nil,
      attempts: 0,
      timer: Process.send_after(self(), {:recovery_deadline, id}, 10_000)
    }
  end

  defp recovery_failure(state, result) do
    if TransferDelivery.retryable?(result) and state.recovery.attempts < 20 do
      token = make_ref()
      delay = min(50 * (state.recovery.attempts + 1), 500)
      timer = Process.send_after(self(), {:retry_recovery, state.recovery.id, token}, delay)

      recovery = %{
        state.recovery
        | stage: :retry,
          attempts: state.recovery.attempts + 1,
          retry_timer: timer,
          retry_token: token,
          job: nil,
          ref: nil
      }

      %{state | recovery: recovery}
    else
      reject(
        state,
        "Inventory recovery could not complete; please retry after the server is repaired"
      )
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
      start_player_login(state, name)
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
        enter_world(state)

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
            continue_life(%{state | respawn_requested: true})

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
        if resume, do: send_velocity(state, state.player.motion.velocity), else: state

      "keep_alive" ->
        <<id::signed-64>> = payload

        case state.keepalive do
          {^id, _} -> %{state | keepalive: nil}
          _ -> reject(state, "Invalid keepalive")
        end

      "move_player_pos" ->
        <<x::float-64, y::float-64, z::float-64, flags>> = payload
        move(admit_position(state), %{x: x, y: y, z: z}, flags)

      "move_player_pos_rot" ->
        <<x::float-64, y::float-64, z::float-64, yaw::float-32, pitch::float-32, flags>> =
          payload

        move(admit_position(state), %{x: x, y: y, z: z, yaw: yaw, pitch: pitch}, flags)

      "move_player_rot" ->
        <<yaw::float-32, pitch::float-32, flags>> = payload
        move(state, %{yaw: yaw, pitch: pitch}, flags)

      "move_player_status_only" ->
        <<flags>> = payload
        move(state, %{}, flags)

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
        update_player_input(state, input)

      "player_command" ->
        {:ok, input} = PlayerInput.receive_command(state.player.input, payload)
        update_player_input(state, input)

      "player_loaded" ->
        <<>> = payload
        update_player_input(state, PlayerInput.loaded(state.player.input))

      "change_game_mode" ->
        {_requested_id, <<>>} = Wire.take_varint(payload)
        # All current network sessions are unprivileged; operators are VMC-010.
        state

      "player_action" ->
        break_block(state, payload)

      "set_carried_item" ->
        <<slot::signed-16>> = payload

        case Inventory.select(state.inventory, slot) do
          {:ok, inventory} ->
            if inventory_pending(state) do
              send_packets(state, [Packets.held_slot(state.inventory.selected)])
              resync_inventory(state)
            else
              send_packets(state, [Packets.held_slot(slot)])

              state =
                if slot != state.inventory.selected and
                     match?(%PlayerUse{hand: :main}, state.active_use),
                   do: stop_item_use(state),
                   else: state

              %{state | inventory: inventory}
            end

          {:error, _} ->
            reject(state, "Invalid hotbar slot")
        end

      "set_creative_mode_slot" ->
        creative_slot(state, payload)

      "container_click" ->
        inventory_click(state, payload)

      "container_close" ->
        {_container, <<>>} = Wire.take_varint(payload)
        inventory_close(state)

      "use_item_on" ->
        place_block(state, payload)

      "use_item" ->
        use_item(state, payload)

      "chat" ->
        {message, _metadata} = Wire.take_string(payload, 256)
        Players.broadcast({:chat, "<#{state.player.name}> #{message}"})
        state

      "chat_command" ->
        {command, <<>>} = Wire.take_string(payload, 256)
        command(state, command)

      nil ->
        reject(state, "Unknown packet ID")

      _known_but_unimplemented ->
        state
    end
  end

  defp handle_packet(state, _, _), do: reject(state, "Unexpected protocol state")

  defp start_player_login(state, name, profile \\ nil) do
    mode = GameMode.new(Valimc.config(:default_game_mode))

    player = %{
      pid: self(),
      name: name,
      uuid: if(profile, do: profile.uuid, else: offline_uuid(name)),
      properties: if(profile, do: profile.properties, else: []),
      entity_id: System.unique_integer([:positive]),
      x: 0.5,
      y: 64.0,
      z: 0.5,
      yaw: 0.0,
      pitch: 0.0,
      game_mode: mode,
      abilities: GameMode.abilities(mode, false),
      input: %PlayerInput{},
      motion: %PlayerMotion{},
      environment: %PlayerEnvironment{},
      air_supply: Valimc.PlayerAir.maximum(),
      food: %PlayerFood{},
      use_flags: 0,
      equipment: %{},
      health: %PlayerHealth{},
      last_death: nil,
      pose: :standing,
      ready: false
    }

    case Players.join(player) do
      :ok -> :ok
      {:error, reason} -> reject(state, reason)
    end

    {store, fence, player, inventory, pending} =
      case PlayerStore.open(player.uuid) do
        {:ok, pid, nil, fence} ->
          {pid, fence, player,
           %{state.inventory | infinite_materials: player.abilities.infinite_materials}, nil}

        {:ok, pid, snapshot, fence} ->
          mode = Map.get(snapshot, :game_mode, player.game_mode)
          abilities = GameMode.abilities(mode, Map.get(snapshot, :flying, false))

          {:ok, velocity} =
            PlayerKinetics.restore_velocity(Map.get(snapshot, :velocity, {0.0, 0.0, 0.0}))

          {:ok, health} = PlayerHealth.restore(Map.get(snapshot, :health))

          inventory = %{
            snapshot.inventory
            | infinite_materials: abilities.infinite_materials
          }

          pending =
            if snapshot.outbox != nil, do: Map.take(snapshot, [:outbox, :transfer_sequence])

          player = %{
            Map.merge(player, snapshot.pose)
            | game_mode: mode,
              abilities: abilities,
              health: health,
              last_death: Map.get(snapshot, :last_death),
              motion:
                PlayerMotion.flight(
                  %PlayerMotion{
                    fall_distance: Map.get(snapshot, :fall_distance, 0.0),
                    velocity: velocity
                  },
                  abilities.flying
                ),
              environment: %PlayerEnvironment{frozen_ticks: Map.get(snapshot, :frozen_ticks, 0)},
              air_supply: Map.get(snapshot, :air_supply, Valimc.PlayerAir.maximum()),
              food: Map.get(snapshot, :food, %PlayerFood{})
          }

          player = if health.value <= 0, do: PlayerLife.dead(player), else: player

          {pid, fence, player, inventory, pending}

        {:error, reason} ->
          require Logger
          Logger.warning("Player state load failed: #{inspect(reason)}")
          reject(state, "Player save unavailable; please retry after storage is repaired")
      end

    Players.update(self(), player)

    state = %{
      state
      | player: player,
        life_stage: if(player.health.value <= 0, do: :sealing_death, else: :alive),
        player_store: store,
        store_fence: fence,
        inventory: inventory,
        store_monitor: Process.monitor(store)
    }

    if pending do
      recovery = new_recovery(:login, :delivery, pending)

      deliver_recovery(%{state | step: :recover, recovery: recovery})
    else
      reconcile_login(state)
    end
  end

  defp enter_world(state) do
    state = publish_equipment(state)

    state = %{
      state
      | phase: :play,
        step: nil,
        player: %{state.player | ready: true},
        login_velocity_pending: state.player.motion.velocity != {0.0, 0.0, 0.0}
    }

    {clock_version, clock_packet} = Valimc.World.Clock.initial()

    {weather_view, weather_packets} =
      WeatherReplication.reconcile(nil, Valimc.World.Clock.weather())

    {difficulty, difficulty_packet} = Valimc.World.Clock.difficulty()

    state = %{
      state
      | clock_version: clock_version,
        weather_view: weather_view,
        difficulty_view: difficulty
    }

    send_packets(state, [
      Packets.login(state.player),
      clock_packet,
      difficulty_packet,
      Packets.abilities(state.player.abilities),
      Packets.health(state.player.health, state.player.food),
      Packets.spawn_position(),
      Packets.commands(),
      Packets.inventory(state.inventory),
      Packets.cursor(state.inventory.carried),
      Packets.held_slot(state.inventory.selected),
      Packets.teleport(state.player, state.teleport),
      Packets.level_load_start(),
      Packets.player_info(state.player),
      Packets.interaction_attributes(state.player),
      Packets.player_environment(state.player),
      Packets.player_pose(state.player),
      Packets.player_health(state.player),
      Packets.player_use(state.player),
      Packets.chat(
        "Welcome to ValiMC. Development preview (#{state.player.game_mode.current}); survival is being built. /help"
      )
    ])

    send_packets(state, weather_packets)

    existing = Players.ready(self())
    state = update_view(state)

    state =
      Enum.reduce(existing, state, fn player, acc -> event(acc, {:player_joined, player}) end)

    clock = TickClock.new(make_ref(), System.monotonic_time(:millisecond))
    Process.send_after(self(), {:player_tick, clock.token}, 50)
    state = %{state | simulation_clock: clock}
    Process.send_after(self(), :publish_movement, 50)
    Process.send_after(self(), :save_player, Valimc.config(:player_save_interval_ms))
    if state.player.health.value <= 0, do: death_notice(state, false), else: state
  end

  defp update_player_input(state, input) do
    if input == state.player.input do
      state
    else
      player = %{state.player | input: input}
      Players.update(self(), player)
      %{state | player: player}
    end
  end

  defp admit_position(state) do
    case ClientTick.position(state.client_tick) do
      {:ok, frame} -> %{state | client_tick: frame}
      {:error, :duplicate_position} -> reject(state, "Invalid player movement")
    end
  end

  defp move(%{teleport_pending: true} = state, _, _), do: state

  defp move(state, changes, flags) do
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
          deadline: System.monotonic_time(:millisecond) + 250,
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

  defp count_motion_packet(state) do
    tick = Integer.floor_div(System.monotonic_time(:millisecond), 50)

    window =
      case state.motion_window do
        %{tick: ^tick} = window -> %{window | packets: window.packets + 1}
        _ -> %{tick: tick, packets: 1, first: Map.take(state.player, [:x, :y, :z])}
      end

    %{state | motion_window: window}
  end

  defp motion_signature(state),
    do: {pose_signature(state), state.player.game_mode.current}

  defp start_motion(
         %{life_stage: :alive, motion_job: nil, teleport_pending: false, motion_pending: input} =
           state
       )
       when input != nil do
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

  defp start_motion(state), do: state

  defp admit_motion(state, input, signature, start) do
    remaining = input.deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      correct_motion(state, :movement_admission_timeout_corrections)
    else
      case start.() do
        {:ok, task} ->
          if input.retry, do: Process.cancel_timer(input.retry)
          Metrics.add(:movement_jobs_started)
          Metrics.add(:movement_admission_wait_ms, 250 - remaining)
          timer = Process.send_after(self(), {:motion_deadline, task.ref}, remaining)

          %{
            state
            | motion_pending: %{input | retry: nil},
              motion_job: %{
                task: task,
                timer: timer,
                input: input,
                signature: signature
              }
          }

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

  defp cancel_pose_job(state) do
    if state.pose_job do
      Process.exit(state.pose_job.task.pid, :kill)
      Process.demonitor(state.pose_job.task.ref, [:flush])
    end

    %{state | pose_job: nil}
  end

  defp cancel_motion_job(state) do
    if state.motion_job do
      Process.cancel_timer(state.motion_job.timer)
      Process.exit(state.motion_job.task.pid, :kill)
      Process.demonitor(state.motion_job.task.ref, [:flush])
    end

    input = state.motion_pending
    if input && input.retry, do: Process.cancel_timer(input.retry)
    input = if input, do: %{input | retry: nil, prepared: nil}
    %{state | motion_job: nil, motion_pending: input}
  end

  defp correct_motion(state, metric) do
    Metrics.add(metric)
    player = %{state.player | motion: PlayerMotion.corrected(state.player.motion)}
    relocate(state, player, false)
  end

  defp relocate(state, player, reset_motion \\ true) do
    state = state |> cancel_pose_job() |> cancel_mining()
    player = if reset_motion, do: %{player | motion: %PlayerMotion{}}, else: player

    if state.motion_pending && state.motion_pending.retry,
      do: Process.cancel_timer(state.motion_pending.retry)

    if state.motion_job do
      Process.cancel_timer(state.motion_job.timer)
      Process.exit(state.motion_job.task.pid, :kill)
      Process.demonitor(state.motion_job.task.ref, [:flush])
    end

    teleport = if state.teleport == 2_147_483_647, do: 0, else: state.teleport + 1
    send_packets(state, [Packets.teleport(player, teleport)])
    Players.update(self(), player)
    send(self(), :drain)

    update_view(%{
      state
      | player: player,
        teleport: teleport,
        teleport_pending: true,
        login_velocity_pending: false,
        motion_job: nil,
        motion_pending: nil,
        motion_window: nil,
        pose_checked: nil,
        pose_generation: state.pose_generation + 1
    })
  end

  defp pose_signature(state),
    do: {PlayerPoseQuery.signature(state.player), state.pose_generation}

  defp sample_pose(
         %{life_stage: :alive, pose_job: nil, motion_pending: nil, teleport_pending: false} =
           state
       ) do
    signature = pose_signature(state)

    active =
      state.simulation_due and
        (PlayerEnvironment.active?(state.player.environment) or
           Valimc.PlayerAir.supply(state.player) < Valimc.PlayerAir.maximum() or
           not state.player.motion.settled)

    if PlayerInput.loaded?(state.player.input) and (signature != state.pose_checked or active) do
      deadline = System.monotonic_time(:millisecond) + 250

      case PlayerPoseQuery.start(state.player) do
        {:ok, task} ->
          %{state | pose_job: %{task: task, signature: signature, deadline: deadline}}

        {:error, _} ->
          state
      end
    else
      state
    end
  end

  defp sample_pose(state), do: state

  defp apply_kinetic_tick(state, result, packet_bounce) do
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

  defp send_velocity(state, velocity) do
    packet = Valimc.Protocol.EntityPackets.motion(state.player.entity_id, velocity)
    send_packets(state, [packet])

    broadcast_player_packet(state, packet)
  end

  defp broadcast_player_packet(state, packet) do
    for pid <- Players.nearby(state.regions),
        pid != self(),
        do: deliver(pid, {:player_packet, self(), state.player.entity_id, packet})

    state
  end

  defp observe_environment(state, powder, submerged, eye_water) do
    due = state.simulation_due
    previous = state.player.environment
    allowed = PlayerEnvironment.can_freeze?(state.player, state.inventory)

    environment =
      PlayerEnvironment.observe(
        previous,
        powder,
        state.simulation_due,
        not allowed
      )

    {damage_due, environment} = PlayerEnvironment.consume_damage(environment, allowed)

    player = %{state.player | environment: environment}

    if environment.frozen_ticks != previous.frozen_ticks or
         (previous.powder_snow and not powder) do
      send_packets(state, [Packets.player_environment(player)])
    end

    Players.update(self(), player)
    state = %{state | player: player, simulation_due: false, mining_water: eye_water}
    state = if due, do: observe_air(state, submerged), else: state

    if damage_due do
      {:ok, selected} = PlayerHealth.hurt_window(state.player.health, 1.0)
      {_, state} = apply_damage(state, selected, :freeze)
      state
    else
      state
    end
  end

  defp observe_air(state, submerged) do
    previous = Valimc.PlayerAir.supply(state.player)
    oxygen = Valimc.PlayerAir.oxygen_bonus(state.inventory)
    draw = if oxygen > 0 and submerged, do: :rand.uniform_real(), else: 0.0

    {air, damage} =
      Valimc.PlayerAir.tick(
        previous,
        submerged,
        state.player.abilities.invulnerable,
        oxygen,
        draw
      )

    player = %{state.player | air_supply: air}
    state = %{state | player: player}

    if air != previous do
      packet = Packets.player_air(player)
      send_packets(state, [packet])
      broadcast_player_packet(state, packet)
      Players.update(self(), player)
    end

    if damage > 0 do
      bubbles = Packets.drowning_bubbles(player.entity_id)
      send_packets(state, [bubbles])
      broadcast_player_packet(state, bubbles)
      {:ok, selected} = PlayerHealth.hurt_window(player.health, damage)
      {_, state} = apply_damage(state, selected, :drown)
      state
    else
      state
    end
  end

  defp monitor_pose_sources(state, fences) do
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

  defp update_view(state) do
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
          pending: pending
      }

      state
    end
  end

  defp stream_chunks(
         %{phase: :play, teleport_pending: false, batch_pending: false, pending: [_ | _]} = state
       ) do
    {batch, pending} = Enum.split(state.pending, 4)

    frames =
      [Packets.frame(Packets.packet("chunk_batch_start", <<>>), state.threshold)] ++
        Enum.map(batch, &World.chunk/1) ++
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
        batch_pending: true
    }
  end

  defp stream_chunks(state), do: state

  defp visible?(state, player) do
    {cx, cz} = World.chunk_key(state.player.x, state.player.z)
    {px, pz} = World.chunk_key(player.x, player.z)
    d = Valimc.config(:view_distance)
    player.pid != self() and abs(cx - px) <= d and abs(cz - pz) <= d
  end

  defp event(%{phase: :play} = state, {:chat, message}) do
    send_packets(state, [Packets.chat(message)])
    state
  end

  defp event(%{phase: :play} = state, {:block, {x, _, z} = pos, block}) do
    if MapSet.member?(state.chunks, World.chunk_key(x, z)),
      do: send_packets(state, [Packets.block(pos, block)])

    mining_changed(%{state | pose_generation: state.pose_generation + 1})
  end

  defp event(%{phase: :play} = state, {:block_batch, updates}) do
    frames = for {chunk, frame} <- updates, MapSet.member?(state.chunks, chunk), do: frame
    send_frames(state, frames)
    mining_changed(%{state | pose_generation: state.pose_generation + 1})
  end

  defp event(%{phase: :play} = state, {:player_joined, player}), do: track_peer(state, player)

  defp event(%{phase: :play} = state, {:player_packet, pid, entity, packet}) do
    case Map.get(state.peers, pid) do
      view when is_tuple(view) and elem(view, 0) == entity -> send_packets(state, [packet])
      _ -> :ok
    end

    state
  end

  defp event(%{phase: :play} = state, {:player_use_packet, pid, entity, packet}) do
    case {Map.get(state.peers, pid), Players.get(pid)} do
      {view, {:ok, %{entity_id: ^entity} = player}} when is_tuple(view) ->
        # Native use starts by refreshing equipment. Sample the current owner
        # publication before sending the animation flag, within this peer view.
        state = track_peer(state, player)
        event(state, {:player_packet, pid, entity, packet})

      _ ->
        state
    end
  end

  defp event(%{phase: :play} = state, {:player_respawned, pid, entity}) do
    case Players.get(pid) do
      {:ok, %{entity_id: ^entity} = player} ->
        if Map.has_key?(state.peers, pid),
          do: send_packets(state, [Packets.remove_entity(player)])

        track_peer(%{state | peers: Map.delete(state.peers, pid)}, player)

      _ ->
        state
    end
  end

  defp event(%{phase: :play} = state, {:player_left, player}) do
    if Map.has_key?(state.peers, player.pid),
      do: send_packets(state, [Packets.remove_entity(player), Packets.remove_info(player)])

    %{state | peers: Map.delete(state.peers, player.pid)}
  end

  defp event(state, _), do: state

  defp track_peer(state, player, mode \\ :direct) do
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
                      Packets.player_health(player)
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

  defp emit_peer_packets(state, packets, :direct) do
    send_packets(state, packets)
    state
  end

  defp emit_peer_packets(state, packets, :buffer),
    do: %{state | outbound: [packets | state.outbound]}

  defp reachable?(state, {x, y, z}) do
    p = state.player

    World.Chunk.valid_y?(y) and
      Valimc.PlayerInteraction.within_block?(
        p.game_mode.current,
        Valimc.PlayerInteraction.eye(p),
        {x, y, z}
      )
  end

  defp break_block(state, payload) do
    {action, payload} = Wire.take_varint(payload)
    {position, <<face, payload::binary>>} = Wire.take_position(payload)
    {sequence, <<>>} = Wire.take_varint(payload)
    if face not in 0..5, do: reject(state, "Invalid action face")

    cond do
      action == ItemTypes.action_id("release_use_item") ->
        stop_item_use(state)

      state.player.game_mode.current == :spectator and
          action in [
            ItemTypes.action_id("drop_item"),
            ItemTypes.action_id("drop_all_items"),
            ItemTypes.action_id("swap_item_with_offhand")
          ] ->
        state

      action in [ItemTypes.action_id("drop_item"), ItemTypes.action_id("drop_all_items")] ->
        drop_selected(state, action == ItemTypes.action_id("drop_all_items"))

      action == ItemTypes.action_id("swap_item_with_offhand") and inventory_pending(state) ->
        resync_inventory(state)

      action == ItemTypes.action_id("swap_item_with_offhand") ->
        state = stop_item_use(state)
        inventory = Inventory.swap_hands(state.inventory)

        send_packets(state, [
          Packets.container_slot(
            inventory.state_id,
            36 + inventory.selected,
            Inventory.held(inventory, :main)
          ),
          Packets.container_slot(inventory.state_id, 45, Inventory.held(inventory, :off))
        ])

        %{state | inventory: inventory}

      true ->
        break_block_action(state, action, position, sequence)
    end
  end

  defp drop_selected(state, _)
       when inventory_pending(state) or state.save_ref != nil,
       do: resync_inventory(state)

  defp drop_selected(state, all) do
    case Inventory.drop_selected(state.inventory, all) do
      {:ok, _inventory, nil} ->
        resync_inventory(state)

      {:ok, inventory, stack} ->
        start_inventory_transfer(state, inventory, [stack])

      {:error, _} ->
        resync_inventory(state)
    end
  end

  defp start_inventory_transfer(state, inventory, stacks, crafting \\ nil)

  defp start_inventory_transfer(state, _, _, _)
       when inventory_pending(state) or state.save_ref != nil,
       do: resync_inventory(state)

  defp start_inventory_transfer(state, inventory, stacks, crafting) do
    # Standing preview eye height minus vanilla's float32 0.3 offset.
    # These entities remain stationary until authoritative item physics exists.
    records =
      Enum.map(stacks, fn stack ->
        %{
          uuid: :crypto.strong_rand_bytes(16),
          x: state.player.x,
          y: state.player.y + 1.3199999928474426,
          z: state.player.z,
          stack: stack
        }
      end)

    key = World.region_key(World.chunk_key(state.player.x, state.player.z))
    ref = make_ref()

    recovery = %{
      new_recovery(:play, :prepare, nil)
      | ref: ref,
        plan: %{key: key, records: records, inventory: inventory}
    }

    before = PlayerSnapshot.capture(state.player, state.inventory)
    after_snapshot = PlayerSnapshot.capture(state.player, inventory)

    if crafting,
      do:
        PlayerStore.prepare_crafting(
          state.player_store,
          state.store_fence,
          before,
          after_snapshot,
          key,
          records,
          crafting,
          ref
        ),
      else:
        PlayerStore.prepare_transfer(
          state.player_store,
          state.store_fence,
          before,
          after_snapshot,
          key,
          records,
          ref
        )

    resync_inventory(%{state | recovery: recovery})
  end

  defp survival_mining_action(state, action, position) do
    cond do
      action == ItemTypes.action_id("abort_destroy_block") ->
        cancel_mining(state)

      action == ItemTypes.action_id("start_destroy_block") ->
        state = state |> cancel_mining() |> stop_item_use()

        if mining_allowed?(state, position) do
          mining = %{
            position: position,
            started: state.simulation_clock.tick,
            requested_at: System.monotonic_time(:millisecond),
            stopped: false,
            attempt: nil,
            reservation: nil,
            needs_check: true,
            renew_at: 0
          }

          tick_mining(%{state | mining: mining})
        else
          correct_mining(state, position)
        end

      action == ItemTypes.action_id("stop_destroy_block") ->
        case state.mining do
          %{position: ^position} = mining ->
            tick_mining(%{state | mining: %{mining | stopped: true}})

          _ ->
            state |> cancel_mining() |> correct_mining(position)
        end

      true ->
        state
    end
  end

  defp mining_allowed?(state, position) do
    state.phase == :play and state.life_stage == :alive and
      state.player.game_mode.current == :survival and state.player.health.value > 0 and
      PlayerInput.loaded?(state.player.input) and not state.teleport_pending and
      not inventory_pending(state) and reachable?(state, position) and
      Valimc.Physics.MiningTools.can_destroy?(Inventory.held(state.inventory, :main), false)
  end

  defp mining_changed(%{mining: nil} = state), do: state
  defp mining_changed(state), do: %{state | mining: %{state.mining | needs_check: true}}

  defp tick_mining(%{mining: nil} = state), do: state

  defp tick_mining(state) do
    mining = state.mining
    now = System.monotonic_time(:millisecond)

    cond do
      not mining_allowed?(state, mining.position) ->
        state |> cancel_mining() |> correct_mining(mining.position)

      state.mining_job != nil ->
        state

      mining.reservation == nil and now - mining.requested_at >= 500 ->
        cancel_mining(state)

      mining.reservation == nil ->
        mining_job(state, :reserve, PlayerMiningQuery.reserve(mining.position), mining.position)

      World.existing_owner(mining.reservation.key) != {:ok, mining.reservation.owner} ->
        state |> cancel_mining() |> correct_mining(mining.position)

      mining.needs_check or now >= mining.renew_at ->
        mining_job(state, :renew, PlayerMiningQuery.renew(mining.reservation), mining.position)

      state.pose_checked != pose_signature(state) or state.motion_pending != nil ->
        state

      true ->
        block = Map.fetch!(mining.reservation.expected, mining.position)

        {:ok, rate} =
          PlayerMining.rate(
            state.inventory,
            block,
            state.mining_water,
            state.player.motion.on_ground
          )

        {attempt, events} =
          if mining.attempt == nil do
            {:ok, attempt, events} =
              PlayerMiningAttempt.start(mining.position, block, rate, mining.started)

            {attempt, events}
          else
            {:ok, attempt, events} =
              PlayerMiningAttempt.tick(mining.attempt, block, rate, state.simulation_clock.tick)

            {attempt, events}
          end

        {attempt, events} =
          if mining.stopped and attempt.phase == :active do
            {:ok, attempt, next} =
              PlayerMiningAttempt.stop(attempt, block, rate, state.simulation_clock.tick)

            {attempt, events ++ next}
          else
            {attempt, events}
          end

        state = %{state | mining: %{mining | attempt: attempt}}

        for {:crack, stage} <- events,
            do:
              broadcast_player_packet(
                state,
                Packets.block_destruction(state.player.entity_id, mining.position, stage)
              )

        if attempt.phase == :ready, do: commit_mining(state), else: state
    end
  end

  defp mining_job(state, kind, {:ok, task}, position) do
    deadline = System.monotonic_time(:millisecond) + 250
    timer = Process.send_after(self(), {:mining_deadline, task.ref}, 250)

    job = %{
      kind: kind,
      task: task,
      timer: timer,
      position: position,
      generation: state.pose_generation,
      deadline: deadline
    }

    %{state | mining_job: job}
  end

  defp mining_job(state, _, {:error, _}, _), do: state

  defp mining_result(
         %{mining: %{position: position} = mining} = state,
         %{kind: :reserve, position: position} = job,
         {:ok, reservation}
       ) do
    block = Map.fetch!(reservation.expected, position)

    mining = %{
      mining
      | reservation: reservation,
        needs_check: job.generation != state.pose_generation,
        renew_at: System.monotonic_time(:millisecond) + 5000
    }

    state = %{state | mining: mining}

    supported =
      block in @basic_mining or
        Valimc.Physics.MiningLoot.ordinary_mining?(block) or
        Valimc.Physics.RandomMiningLoot.supported?(block) or
        MapSet.member?(@slab_blocks, Valimc.Physics.MiningTools.block_id(block))

    if supported and mining_allowed?(state, position) do
      tick_mining(state)
    else
      send_packets(state, [Packets.block(position, block)])
      cancel_mining(state)
    end
  end

  defp mining_result(%{mining: mining} = state, %{kind: :renew} = job, {:ok, expected})
       when mining != nil do
    if expected == mining.reservation.expected do
      mining = %{
        mining
        | needs_check: job.generation != state.pose_generation,
          renew_at: System.monotonic_time(:millisecond) + 5000
      }

      tick_mining(%{state | mining: mining})
    else
      state |> cancel_mining() |> correct_mining(job.position)
    end
  end

  defp mining_result(state, %{kind: :correct} = job, {:ok, owner, block}) do
    key = World.region_key(World.chunk_key(elem(job.position, 0), elem(job.position, 2)))

    if job.generation == state.pose_generation and World.existing_owner(key) == {:ok, owner} and
         reachable?(state, job.position),
       do: send_packets(state, [Packets.block(job.position, block)])

    state
  end

  defp mining_result(state, %{kind: :correct}, _), do: state
  defp mining_result(state, job, _), do: state |> cancel_mining() |> correct_mining(job.position)

  defp cancel_mining(state) do
    if state.mining_job do
      Process.cancel_timer(state.mining_job.timer)
      Process.exit(state.mining_job.task.pid, :kill)
      Process.demonitor(state.mining_job.task.ref, [:flush])
    end

    if state.mining do
      mining = state.mining

      broadcast_player_packet(
        state,
        Packets.block_destruction(state.player.entity_id, mining.position, -1)
      )

      if mining.reservation, do: PlayerMiningQuery.release(mining.reservation)
    end

    %{state | mining: nil, mining_job: nil}
  end

  defp correct_mining(state, position) do
    if state.mining_job == nil and reachable?(state, position),
      do: mining_job(state, :correct, PlayerMiningQuery.observe(position), position),
      else: state
  end

  defp correct_block_recovery(state, recovery) do
    intent = if recovery.intent, do: recovery.intent[:outbox], else: recovery.plan[:intent]

    case {recovery.mode, intent} do
      {:play, %{kind: :mining}} ->
        correct_mining(state, intent.target)

      {:play, %{kind: :placement}} ->
        correct_placement(state, intent.request, recovery.plan.reservation)

      _ ->
        state
    end
  end

  defp commit_mining(%{save_ref: ref} = state) when ref != nil, do: state

  defp commit_mining(state) do
    mining = state.mining
    reservation = mining.reservation
    block = Map.fetch!(reservation.expected, mining.position)
    before = Inventory.held(state.inventory, :main)

    {:ok, drops} =
      Valimc.Physics.MiningLoot.drops(
        block,
        before,
        PlayerMining.harvest?(state.inventory, block)
      )

    {after_tool, _broken} = Valimc.ToolDurability.mine(before, block, false)
    {x, y, z} = mining.position

    records =
      Enum.map(drops, fn stack ->
        %{uuid: :crypto.strong_rand_bytes(16), x: x + 0.5, y: y + 0.5, z: z + 0.5, stack: stack}
      end)

    slot = 36 + state.inventory.selected

    slots =
      if after_tool,
        do: Map.put(state.inventory.slots, slot, after_tool),
        else: Map.delete(state.inventory.slots, slot)

    inventory =
      %{state.inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()

    intent =
      reservation
      |> Map.take([:key, :permit, :expected])
      |> Map.merge(%{
        kind: :mining,
        target: mining.position,
        slot: slot,
        before: before,
        after: after_tool,
        records: records
      })

    ref = make_ref()

    recovery = %{
      new_recovery(:play, :prepare, nil)
      | ref: ref,
        plan: %{key: reservation.key, records: records, inventory: inventory, intent: intent}
    }

    PlayerStore.prepare_mining(
      state.player_store,
      state.store_fence,
      PlayerSnapshot.capture(state.player, state.inventory),
      intent,
      ref
    )

    # This intent now resolves through the durable lane; attempt cancellation must not release its permit.
    %{state | mining: nil, recovery: recovery}
  end

  defp break_block_action(
         %{player: %{game_mode: %{current: :survival}}} = state,
         action,
         position,
         sequence
       ) do
    send_packets(state, [Packets.ack(sequence)])
    survival_mining_action(state, action, position)
  end

  defp break_block_action(state, action, position, sequence) do
    if action in [
         ItemTypes.action_id("start_destroy_block"),
         ItemTypes.action_id("stop_destroy_block")
       ] and state.player.game_mode.current == :creative and reachable?(state, position),
       do: World.remove_block(position)

    updates =
      if reachable?(state, position),
        do: [Packets.block(position, World.get_block(position))],
        else: []

    send_packets(state, [Packets.ack(sequence) | updates])

    state
  end

  defp creative_slot(state, <<slot::signed-16, payload::binary>>) do
    case ItemStack.decode(payload, :untrusted) do
      {:ok, stack} ->
        cond do
          not state.inventory.infinite_materials ->
            resync_inventory(state)

          state.recovery != nil and not creative_pending?(state) ->
            resync_inventory(state)

          slot < 0 ->
            creative_drop(state, stack, byte_size(payload) + 2)

          slot in 1..45 ->
            if state.recovery == nil and state.creative_input.queued == 0,
              do: write_creative_slot(state, slot, stack),
              else: enqueue_creative(state, {:slot, slot, stack}, byte_size(payload) + 2)

          true ->
            resync_inventory(state)
        end

      {:unsupported, _names} ->
        send_packets(state, [
          Packets.chat("This item's components are not supported yet; slot restored")
        ])

        if slot in 1..45, do: correct_creative_slot(state, slot), else: resync_inventory(state)

      {:error, _} ->
        reject(state, "Malformed or invalid creative item")
    end
  end

  defp creative_tick, do: Integer.floor_div(System.monotonic_time(:millisecond), 50)

  defp creative_pending?(%{recovery: %{mode: :play, plan: %{kind: :creative_creation}}}),
    do: true

  defp creative_pending?(_), do: false

  # Do not overwrite valid client predictions with an earlier creative snapshot
  # while their following slot updates are still deferred.
  defp sync_creative_result(%{life_stage: stage} = state) when stage != :alive, do: state

  defp sync_creative_result(state) do
    if creative_pending?(state) or state.creative_input.queued > 0,
      do: state,
      else: resync_inventory(state)
  end

  defp creative_drop(state, stack, bytes) do
    {result, input} = CreativeInput.charge(state.creative_input, creative_tick())
    state = %{state | creative_input: input}

    if result == :ok and stack != nil do
      key = World.region_key(World.chunk_key(state.player.x, state.player.z))

      record = %{
        uuid: :crypto.strong_rand_bytes(16),
        x: state.player.x,
        y: state.player.y + 1.3199999928474426,
        z: state.player.z,
        stack: stack
      }

      enqueue_creative(state, {:create, key, record}, bytes)
    else
      resync_inventory(state)
    end
  end

  defp enqueue_creative(state, command, bytes) do
    case CreativeInput.push(state.creative_input, command, bytes) do
      {:ok, input} ->
        drain_creative(%{state | creative_input: input})

      {:error, _} ->
        send_packets(state, [Packets.chat("Creative input queue is full; inventory restored")])
        resync_inventory(state)
    end
  end

  defp drain_creative(state), do: drain_creative(state, 64)
  defp drain_creative(state, _) when state.recovery != nil or state.save_ref != nil, do: state
  defp drain_creative(state, _) when state.creative_input.queued == 0, do: state

  defp drain_creative(state, _) when not state.inventory.infinite_materials,
    do: resync_inventory(%{state | creative_input: CreativeInput.clear(state.creative_input)})

  defp drain_creative(state, 0) do
    if not state.creative_drain_scheduled, do: send(self(), :drain_creative)
    %{state | creative_drain_scheduled: true}
  end

  defp drain_creative(state, budget) do
    {:ok, command, input} = CreativeInput.pop(state.creative_input)
    state = %{state | creative_input: input}

    case command do
      {:slot, slot, stack} ->
        state
        |> write_creative_slot(slot, stack, state.creative_input.queued == 0)
        |> drain_creative(budget - 1)

      {:create, key, record} ->
        ref = make_ref()

        recovery = %{
          new_recovery(:play, :prepare, nil)
          | ref: ref,
            plan: %{
              kind: :creative_creation,
              key: key,
              records: [record],
              inventory: state.inventory
            }
        }

        PlayerStore.prepare_creative_drop(
          state.player_store,
          state.store_fence,
          PlayerSnapshot.capture(state.player, state.inventory),
          key,
          record,
          ref
        )

        %{state | recovery: recovery, inventory: Inventory.cancel_drag(state.inventory)}
    end
  end

  defp write_creative_slot(state, slot, stack, publish \\ true) do
    case Inventory.creative(state.inventory, slot, stack) do
      {:ok, inventory} ->
        if publish do
          updates = [Packets.container_slot(inventory.state_id, slot, stack)]

          updates =
            if slot in 1..4,
              do:
                updates ++
                  [
                    Packets.container_slot(
                      inventory.state_id,
                      0,
                      Inventory.crafting_result(inventory)
                    )
                  ],
              else: updates

          send_packets(state, updates)
        end

        %{state | inventory: inventory}

      {:error, _} ->
        resync_inventory(state)
    end
  end

  defp correct_creative_slot(state, slot) do
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()

    send_packets(state, [
      Packets.container_slot(inventory.state_id, slot, Inventory.get(inventory, slot))
    ])

    %{state | inventory: inventory}
  end

  defp resync_inventory(state) do
    inventory = state.inventory |> Inventory.cancel_drag() |> Inventory.advance()
    send_packets(state, [Packets.inventory(inventory), Packets.cursor(inventory.carried)])
    %{state | inventory: inventory}
  end

  defp inventory_close(state) when inventory_pending(state),
    do: resync_inventory(state)

  defp inventory_close(state) do
    case Inventory.close(state.inventory) do
      {:ok, inventory, []} ->
        send_packets(state, [Packets.inventory(inventory), Packets.cursor(nil)])
        %{state | inventory: inventory}

      {:ok, inventory, [_ | _] = stacks} ->
        start_inventory_transfer(state, inventory, stacks)

      {:error, _} ->
        send_packets(state, [
          Packets.chat("Menu return exceeds inventory limits; inventory restored")
        ])

        resync_inventory(state)
    end
  end

  defp inventory_click(state, payload) do
    case InventoryClick.decode(payload) do
      {:ok, %{container: 0}} when inventory_pending(state) ->
        resync_inventory(state)

      {:ok, %{container: 0}} when state.player.game_mode.current == :spectator ->
        resync_inventory(state)

      {:ok, %{container: 0} = click} ->
        # The vanilla listener applies actions to current owner state even when
        # the reported state ID is stale. Predictions only guide replication.
        case Inventory.plan_click(state.inventory, click.action, click.slot, click.button) do
          {:ok, inventory, []} ->
            send_packets(state, [Packets.inventory(inventory), Packets.cursor(inventory.carried)])
            %{state | inventory: inventory}

          {:ok, inventory, [_ | _] = stacks} ->
            crafting = if click.slot == 0, do: {click.action, click.button}
            start_inventory_transfer(state, inventory, stacks, crafting)

          {:error, _} ->
            send_packets(state, [
              Packets.chat("This inventory operation is not supported yet; state restored")
            ])

            resync_inventory(state)
        end

      {:ok, click} ->
        send_packets(state, [Packets.packet("container_close", Wire.varint(click.container))])
        resync_inventory(state)

      {:error, _} ->
        reject(state, "Malformed inventory click")
    end
  end

  defp place_block(state, payload) do
    case UseItemOn.decode(payload) do
      {:ok, request} ->
        stack = Inventory.held(state.inventory, request.hand)

        cond do
          not Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) or
              not reachable?(state, request.position) ->
            send_packets(state, [Packets.ack(request.sequence)])
            resync_inventory(state)

          stack != nil and Valimc.Physics.Placement.supported_item?(stack.item_id) ->
            if state.placement_queued >= 16,
              do: reject(state, "Too many pending block interactions")

            body = placement_body(state, request)

            command = %{
              request: request,
              item: stack.item_id,
              stack: stack,
              slot: if(request.hand == :off, do: 45, else: 36 + state.inventory.selected),
              mode: state.player.game_mode.current,
              body: body,
              expires: System.monotonic_time(:millisecond) + 250
            }

            drain_placements(%{
              state
              | placement_queue: :queue.in(command, state.placement_queue),
                placement_queued: state.placement_queued + 1
            })

          true ->
            preview_placement(state, request, stack)
        end

      {:error, _} ->
        reject(state, "Malformed block interaction")
    end
  end

  defp placement_body(state, request) do
    mode = state.player.game_mode.current

    if state.life_stage == :alive and state.player.health.value > 0 and
         ((mode == :creative and state.inventory.infinite_materials) or
            (mode == :survival and not state.inventory.infinite_materials)) and
         PlayerInput.loaded?(state.player.input) and
         not state.teleport_pending and not inventory_pending(state) and
         reachable?(state, request.position) and
         Valimc.PlayerInteraction.valid_hit?(request.position, request.cursor) do
      {:ok, geometry} =
        Valimc.Physics.PlayerPose.geometry(
          state.player.pose,
          {state.player.x, state.player.y, state.player.z}
        )

      %{box: geometry.box, chunks: state.chunks}
    end
  end

  defp drain_placements(%{placement_job: job} = state) when job != nil, do: state

  defp drain_placements(state)
       when state.recovery != nil or state.save_ref != nil or state.use_save != nil,
       do: state

  defp drain_placements(state) do
    case :queue.out(state.placement_queue) do
      {:empty, _} ->
        state

      {{:value, command}, queue} ->
        state = %{state | placement_queue: queue, placement_queued: state.placement_queued - 1}

        start =
          if command.mode == :survival,
            do: &PlayerPlacementQuery.start_survival/4,
            else: &PlayerPlacementQuery.start_creative/4

        case start.(
               command.item,
               command.request,
               command.body,
               command.expires
             ) do
          {:ok, task} ->
            timer = Process.send_after(self(), {:placement_deadline, task.ref}, 750)
            %{state | placement_job: %{task: task, timer: timer, command: command}}

          {:error, _} ->
            reject(state, "Block interaction capacity reached; please reconnect")
        end
    end
  end

  defp prepare_survival_placement(state, command, reservation) do
    if command.body != nil and state.life_stage == :alive and state.player.health.value > 0 and
         state.player.game_mode.current == :survival and not state.inventory.infinite_materials and
         not state.teleport_pending and not inventory_pending(state) and state.save_ref == nil and
         System.monotonic_time(:millisecond) < command.expires and
         command.slot ==
           if(command.request.hand == :off, do: 45, else: 36 + state.inventory.selected) and
         Inventory.get(state.inventory, command.slot) == command.stack do
      after_stack =
        if command.stack.count == 1,
          do: nil,
          else: %{command.stack | count: command.stack.count - 1}

      slots =
        if after_stack,
          do: Map.put(state.inventory.slots, command.slot, after_stack),
          else: Map.delete(state.inventory.slots, command.slot)

      inventory =
        %{state.inventory | slots: slots} |> Inventory.cancel_drag() |> Inventory.advance()

      intent =
        reservation
        |> Map.take([:key, :permit, :expected])
        |> Map.merge(%{
          kind: :placement,
          slot: command.slot,
          before: command.stack,
          after: after_stack,
          request: command.request,
          edits: %{reservation.candidate.position => reservation.candidate.state}
        })

      ref = make_ref()

      recovery = %{
        new_recovery(:play, :prepare, nil)
        | ref: ref,
          plan: %{
            key: reservation.key,
            records: [],
            inventory: inventory,
            intent: intent,
            reservation: reservation
          }
      }

      PlayerStore.prepare_placement(
        state.player_store,
        state.store_fence,
        PlayerSnapshot.capture(state.player, state.inventory),
        intent,
        ref
      )

      state |> cancel_mining() |> stop_item_use() |> Map.put(:recovery, recovery)
    else
      correct_placement(state, command.request, reservation)
    end
  end

  defp correct_placement(state, request, reservation) do
    case PlayerPlacementQuery.start_correction(request, reservation) do
      {:ok, task} ->
        timer = Process.send_after(self(), {:placement_deadline, task.ref}, 750)

        %{
          state
          | placement_job: %{
              task: task,
              timer: timer,
              command: %{mode: :correction, body: nil, request: request}
            }
        }

      {:error, _} ->
        reject(state, "Block correction capacity reached; please reconnect")
    end
  end

  defp preview_placement(
         state,
         %{position: position, cursor: cursor, sequence: sequence} = request,
         stack
       ) do
    target = Valimc.Physics.Placement.adjacent(request)

    item = if stack, do: Data.item_block(stack.item_id)

    allowed =
      Valimc.PlayerInteraction.valid_hit?(position, cursor) and reachable?(state, position)

    if not inventory_pending(state) and state.player.game_mode.current == :creative and
         item != nil and allowed and World.Chunk.valid_y?(elem(target, 1)),
       do: World.set_block(target, item)

    updates =
      if allowed and World.Chunk.valid_y?(elem(target, 1)),
        do: [
          Packets.block(position, World.get_block(position)),
          Packets.block(target, World.get_block(target))
        ],
        else: []

    send_packets(state, [Packets.ack(sequence) | updates])

    if inventory_pending(state) or state.player.game_mode.current != :creative,
      do: resync_inventory(state),
      else: state
  end

  defp command(state, input), do: execute_command(state, Valimc.Commands.resolve(input))

  defp execute_command(state, :help) do
    send_packets(state, [
      Packets.chat(Valimc.Commands.help_text())
    ])

    state
  end

  defp execute_command(state, :stats) do
    stats = Metrics.snapshot()

    send_packets(state, [
      Packets.chat(
        "#{stats.players} players · #{stats.regions} regions · #{stats.schedulers} schedulers · #{div(stats.memory_bytes, 1_048_576)} MiB"
      )
    ])

    state
  end

  defp execute_command(state, :spawn) do
    if state.life_stage == :alive,
      do: relocate(state, %{state.player | x: 0.5, y: 64.0, z: 0.5}),
      else: state
  end

  defp execute_command(state, :unknown) do
    send_packets(state, [Packets.chat("Unknown command. Use /help.")])
    state
  end

  defp send_packets(state, packets),
    do: send_frames(state, Enum.map(packets, &Packets.frame(&1, state.threshold)))

  defp send_frames(_state, []), do: :ok

  defp send_frames(state, frames) do
    size = IO.iodata_length(frames)

    if size > Valimc.config(:max_write_batch_bytes),
      do: throw({:disconnect, :write_batch_too_large, state})

    bytes =
      if state.cipher,
        do: crypt_bytes(state.cipher, :encrypt, IO.iodata_to_binary(frames)),
        else: frames

    case :gen_tcp.send(state.socket, bytes) do
      :ok ->
        Metrics.add(:bytes_sent, size)
        Metrics.add(:packets_sent, length(frames))
        :ok

      {:error, reason} ->
        throw({:disconnect, reason, state})
    end
  end

  defp crypt_bytes(nil, _, bytes), do: bytes

  defp crypt_bytes(cipher, direction, bytes) do
    size = Encryption.max_chunk()

    chunks =
      Stream.unfold(bytes, fn
        <<>> ->
          nil

        remaining ->
          count = min(byte_size(remaining), size)
          <<part::binary-size(^count), tail::binary>> = remaining
          {part, tail}
      end)

    chunks
    |> Enum.map(fn chunk ->
      {:ok, transformed} = apply(Encryption, direction, [cipher, chunk])
      transformed
    end)
    |> IO.iodata_to_binary()
  end

  defp reject(state, message) do
    Metrics.add(:connections_rejected)
    if state.phase in [:handshake, :status], do: throw({:disconnect, message, state})

    payload =
      if state.phase == :login,
        do: Wire.string(IO.iodata_to_binary(:json.encode(%{text: message}))),
        else: Wire.text_component(message)

    phase = if state.phase in [:login, :configuration, :play], do: state.phase, else: :login
    name = if phase == :login, do: "login_disconnect", else: "disconnect"

    send_packets(state, [Packets.packet(name, payload, phase)])

    throw({:disconnect, message, state})
  end

  def offline_uuid(name) do
    <<a::48, b::16, c::16, d::48>> = :crypto.hash(:md5, "OfflinePlayer:" <> name)
    <<a::48, (b &&& 0x0FFF) ||| 0x3000::16, (c &&& 0x3FFF) ||| 0x8000::16, d::48>>
  end

  @impl true
  def terminate(_reason, state) do
    cancel_mining(state)

    if state.placement_job do
      Process.cancel_timer(state.placement_job.timer)
      Process.exit(state.placement_job.task.pid, :kill)
      Process.demonitor(state.placement_job.task.ref, [:flush])
    end

    :gen_tcp.close(state.socket)

    if state.motion_pending && state.motion_pending.retry,
      do: Process.cancel_timer(state.motion_pending.retry)

    if state.pose_job do
      Process.exit(state.pose_job.task.pid, :kill)
      Process.demonitor(state.pose_job.task.ref, [:flush])
    end

    if state.motion_job do
      Process.cancel_timer(state.motion_job.timer)
      Process.exit(state.motion_job.task.pid, :kill)
      Process.demonitor(state.motion_job.task.ref, [:flush])
    end

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
      # Read the latest owner publication for movement accepted before a failure.
      snapshot =
        case state.life_save do
          %{kind: :respawn, snapshot: snapshot} ->
            snapshot

          _ ->
            player =
              case Players.get(self()) do
                {:ok, latest} -> latest
                :error -> state.player
              end

            PlayerSnapshot.capture(player, state.inventory)
        end

      try do
        PlayerStore.close_session(
          state.player_store,
          state.store_fence,
          snapshot
        )
      catch
        :exit, _ ->
          require Logger
          Logger.error("Player state final save could not complete")
      end
    end
  end
end
