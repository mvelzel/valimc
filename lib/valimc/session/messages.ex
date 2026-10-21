defmodule Valimc.Session.Messages do
  @moduledoc "The connection's message router: socket data, worker replies, store acknowledgements, ticks and deliveries (VMC-069)."

  require Logger

  alias Valimc.Protocol.{
    EffectTypes,
    Encryption,
    Packets
  }

  alias Valimc.Session.Jobs
  alias Valimc.Session.Events
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
    only: [send_packets: 2, crypt_bytes: 3, reject: 2, reset_window: 1]

  alias Valimc.{
    Metrics,
    Players,
    PlayerContainerQuery,
    PlayerAirEffects,
    PlayerEnvironment,
    PlayerHealth,
    PlayerInput,
    PlayerPickupIntent,
    PlayerSnapshot,
    PlayerStore,
    TransferDelivery,
    World
  }

  alias Valimc.World.TickClock

  alias Valimc.World.{
    BorderReplication,
    ChestLidReplication,
    EntityReplication,
    WeatherReplication
  }

  # Vanilla tracking ranges, in chunks, of the entity kinds regions own (VMC-070).
  @tracking_ranges %{
    item: Valimc.Protocol.EntityTypes.tracking_range("item"),
    orb: Valimc.Protocol.EntityTypes.tracking_range("experience_orb")
  }
  @entity_range @tracking_ranges |> Map.values() |> Enum.max()
  @resistance EffectTypes.id("resistance")
  # Events region owners publish to their visibility topics (`Valimc.World.publish/2`).
  @region_events [
    :block,
    :block_batch,
    :level_events,
    :chest_lid,
    :item_pickup,
    :experience_pickup
  ]

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  def info(:activate, state) do
    :ok = :inet.setopts(state.socket, active: :once)
    Process.send_after(self(), :login_deadline, Valimc.config(:login_timeout_ms))
    Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))
    Metrics.add(:connections_accepted)
    {:noreply, %{state | active: true}}
  end

  def info({:tcp, socket, data}, %{socket: socket} = state) do
    Valimc.Connection.guard_connection(state, fn ->
      state = reset_window(state)
      bytes = state.bytes + byte_size(data)
      if bytes > Valimc.config(:bytes_per_second), do: reject(state, "Inbound byte rate exceeded")

      if byte_size(state.buffer) + byte_size(data) > Valimc.config(:max_packet_bytes) + 5,
        do: reject(state, "Receive buffer exceeded")

      data = crypt_bytes(state.cipher, :decrypt, data)

      Valimc.Connection.consume(
        %{state | buffer: state.buffer <> data, bytes: bytes, active: false},
        64
      )
    end)
  end

  def info(:drain, state),
    do: Valimc.Connection.guard_connection(state, fn -> Valimc.Connection.consume(state, 64) end)

  def info({:tcp_closed, _}, state), do: {:stop, :normal, state}
  def info({:tcp_error, _, _}, state), do: {:stop, :normal, state}

  def info(
        {:key_verified, worker, token, result},
        %{key_job: %{pid: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.KeyExchange.cancel(job)
    state = %{state | key_job: nil}

    Valimc.Connection.guard_connection(state, fn ->
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
            Valimc.Connection.consume(state, 64)
          end

        _ ->
          reject(state, "Invalid login encryption response")
      end
    end)
  end

  def info({:key_verified, _, _, _}, state), do: {:noreply, state}

  def info(
        {:session_verified, worker, token, result},
        %{auth_job: %{pid: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    Valimc.Auth.SessionJobs.cancel(job)
    state = %{state | auth_job: nil}

    Valimc.Connection.guard_connection(state, fn ->
      if System.monotonic_time(:millisecond) >= job.deadline,
        do: reject(state, "Authentication timed out")

      case result do
        {:ok, profile} ->
          if not Valimc.Auth.Profile.valid?(profile, state.login_name),
            do: reject(state, "Invalid authentication profile")

          state = LoginFlow.start_player_login(%{state | step: nil}, state.login_name, profile)
          Valimc.Connection.consume(state, 64)

        {:error, :unverified_session} ->
          reject(state, "Failed to verify username")

        _ ->
          reject(state, "Authentication servers unavailable; please retry")
      end
    end)
  end

  def info({:session_verified, _, _, _}, state), do: {:noreply, state}

  def info({:session_deadline, token}, %{auth_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do:
        Valimc.Connection.guard_connection(state, fn ->
          reject(state, "Authentication timed out")
        end),
      else: {:noreply, state}
  end

  def info({:session_deadline, _}, state), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, %{auth_job: %{monitor: ref}} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        reject(state, "Authentication servers unavailable; please retry")
      end)

  def info({:key_deadline, token}, %{key_job: %{token: token} = job} = state) do
    if System.monotonic_time(:millisecond) >= job.deadline,
      do:
        Valimc.Connection.guard_connection(state, fn ->
          reject(state, "Login encryption timed out")
        end),
      else: {:noreply, state}
  end

  def info({:key_deadline, _}, state), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, %{key_job: %{monitor: ref}} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        reject(state, "Login encryption unavailable")
      end)

  def info({:table_deadline, ref}, %{table_job: %{ref: ref}} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Menus.fail_table_query(state)}
      end)

  def info({:table_deadline, _}, state), do: {:noreply, state}

  def info(
        {:DOWN, ref, :process, _, _},
        %{table_menu: %{kind: kind, monitor: ref}} = state
      )
      when kind in [:chest, :cooking],
      do:
        Valimc.Connection.guard_connection(state, fn ->
          {:noreply, Menus.begin_table_close(state)}
        end)

  def info({:DOWN, ref, :process, _, _}, %{table_job: %{monitor: ref}} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Menus.fail_table_query(state)}
      end)

  def info(
        {:container_candidate, ref, result},
        %{jobs: %{active: %{experience: %{ref: ref, stage: :candidate} = job}}} = state
      ) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def info(
        {:container_candidate, ref, result},
        %{table_job: %{kind: :container, stage: :candidate, ref: ref} = job} = state
      ) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def info({:container_candidate, _, _}, state), do: {:noreply, state}

  def info(
        {ref, result},
        %{table_job: %{kind: :container, task: %Task{ref: ref}} = job} = state
      ) do
    Process.demonitor(ref, [:flush])
    state = %{state | table_job: %{job | task: nil}}

    Valimc.Connection.guard_connection(state, fn ->
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

  def info(
        {:DOWN, ref, :process, _, _},
        %{table_job: %{kind: :container, task: %Task{ref: ref}}} = state
      ),
      do:
        Valimc.Connection.guard_connection(state, fn ->
          {:noreply, Menus.fail_chest_action(state)}
        end)

  def info(:save_player, state) do
    Process.send_after(self(), :save_player, Valimc.config(:player_save_interval_ms))
    info(:save_player_now, state)
  end

  # `/save-all` (VMC-010b): a checkpoint now, outside the periodic schedule.
  def info(:save_player_now, state) do
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

  def info({:player_saved, ref, :ok}, %{life_save: %{ref: ref} = save} = state) do
    Valimc.Connection.guard_connection(state, fn ->
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

          :travel ->
            Valimc.Player.Travel.finish(state, save.player)
        end

      {:noreply, state}
    end)
  end

  def info({:player_saved, ref, :ok}, %{save_ref: ref} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply,
         %{state | save_ref: nil, use_save: nil}
         |> CreativeInventory.drain_creative()
         |> Vitals.continue_life()
         |> Valimc.Player.Travel.continue()
         |> Menus.continue_table_close()
         |> Menus.continue_crafting_repeat()
         |> Menus.drain_table_clicks()
         |> Placement.drain_placements()}
      end)

  def info(:drain_creative, %{creative_drain_scheduled: true} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply,
         state
         |> Map.put(:creative_drain_scheduled, false)
         |> CreativeInventory.drain_creative()
         |> CreativeInventory.sync_creative_result()}
      end)

  def info(:drain_creative, state), do: {:noreply, state}

  def info({:player_saved, ref, {:error, _}}, %{save_ref: ref} = state),
    do: Valimc.Connection.guard_connection(state, fn -> reject(state, "Player save failed") end)

  def info({:save_deadline, ref}, %{save_ref: ref} = state),
    do:
      Valimc.Connection.guard_connection(state, fn -> reject(state, "Player save timed out") end)

  def info({:save_deadline, _}, state), do: {:noreply, state}

  def info(
        {:transfer_delivered, worker, token, result},
        %{recovery: %{stage: :delivery, job: %{pid: worker, token: token} = job} = recovery} =
          state
      ) do
    Process.demonitor(job.monitor, [:flush])
    state = %{state | recovery: %{recovery | job: nil}}

    Valimc.Connection.guard_connection(state, fn ->
      if TransferDelivery.completed?(state.recovery.intent, result) do
        ref = make_ref()
        PlayerStore.complete_transfer(state.player_store, state.store_fence, ref)
        {:noreply, %{state | recovery: %{state.recovery | stage: :complete, ref: ref}}}
      else
        {:noreply, Transfers.recovery_failure(state, result)}
      end
    end)
  end

  def info({:transfer_delivered, _, _, _}, state), do: {:noreply, state}

  def info(
        {:player_transfer_saved, ref, {:ok, fence, snapshot}},
        %{recovery: %{stage: :prepare, ref: ref, plan: plan} = recovery} = state
      ) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def info(
        {:player_transfer_saved, ref, {:error, reason}},
        %{recovery: %{stage: :prepare, ref: ref} = recovery} = state
      ) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def info(
        {:player_transfer_saved, ref, {:ok, fence, snapshot}},
        %{recovery: %{stage: :complete, ref: ref} = recovery} = state
      ) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def info(
        {:player_transfer_saved, ref, {:error, _} = error},
        %{recovery: %{stage: :complete, ref: ref}} = state
      ),
      do:
        Valimc.Connection.guard_connection(state, fn ->
          {:noreply, Transfers.recovery_failure(state, error)}
        end)

  def info({:player_transfer_saved, _, _}, state), do: {:noreply, state}

  def info(
        {:retry_recovery, id, token},
        %{recovery: %{id: id, stage: :retry, retry_token: token} = recovery} = state
      ) do
    state = %{state | recovery: %{recovery | retry_timer: nil}}

    Valimc.Connection.guard_connection(state, fn ->
      {:noreply, Transfers.deliver_recovery(state)}
    end)
  end

  def info({:retry_recovery, _, _}, state), do: {:noreply, state}

  def info({:recovery_deadline, id}, %{recovery: %{id: id}} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        reject(state, "Inventory recovery is still pending; please retry later")
      end)

  def info({:recovery_deadline, _}, state), do: {:noreply, state}

  def info(
        {:DOWN, monitor, :process, worker, _},
        %{recovery: %{stage: :delivery, job: %{pid: worker, monitor: monitor}} = recovery} =
          state
      ) do
    state = %{state | recovery: %{recovery | job: nil}}

    Valimc.Connection.guard_connection(state, fn ->
      {:noreply, Transfers.recovery_failure(state, {:error, :region_restarting})}
    end)
  end

  def info({:retry_motion, token}, %{motion_pending: %{token: token} = input} = state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Movement.start_motion(%{state | motion_pending: %{input | retry: nil}})}
      end)

  def info({:retry_motion, _}, state), do: {:noreply, state}

  # Cancelling geometry retires its reference; a result already in this mailbox
  # must never become a new player input or crash a healthy connection.
  def info({ref, _}, state) when is_reference(ref), do: {:noreply, state}

  def info({:DOWN, ref, :process, _, _}, %{store_monitor: ref} = state),
    do:
      Valimc.Connection.guard_connection(state, fn -> reject(state, "Player storage stopped") end)

  def info({:DOWN, ref, :process, pid, _}, state) do
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

  def info(:login_deadline, %{phase: :play} = state), do: {:noreply, state}
  def info(:login_deadline, state), do: {:stop, :normal, state}

  def info(:keepalive, state) do
    Valimc.Connection.guard_connection(state, fn ->
      Process.send_after(self(), :keepalive, Valimc.config(:keepalive_interval_ms))

      if state.phase == :play do
        now = System.monotonic_time(:millisecond)
        timeout = Valimc.config(:keepalive_timeout_ms)

        idle = Valimc.Admin.Lists.idle_timeout()

        case state.keepalive do
          {_, sent} when now - sent > timeout ->
            reject(state, "Keepalive timed out")

          # VMC-010c: the idle kick, checked with each keepalive.
          _ when idle > 0 and now - state.last_action > idle * 60_000 ->
            reject(
              state,
              Valimc.Command.Text.encode(
                Valimc.Command.Text.translatable("multiplayer.disconnect.idling")
              )
            )

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

  def info(
        {:player_tick, token},
        %{phase: :play, simulation_clock: %TickClock{} = clock} = state
      ) do
    Valimc.Connection.guard_connection(state, fn ->
      case TickClock.advance(clock, token, System.monotonic_time(:millisecond)) do
        {:ok, next, late, delay} ->
          schedule_player_tick(state, next, delay)
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
           |> Vitals.apply_border_damage()
           |> ItemUse.tick_item_use()
           |> Vitals.tick_food()
           |> Vitals.reset_effect_fall()
           |> Mining.tick_mining()
           |> Menus.continue_table_close()
           |> Menus.continue_crafting_repeat()
           |> Menus.check_table_menu()
           |> Valimc.Player.Portals.tick()
           |> Valimc.Player.Travel.tick()
           |> Movement.start_motion()
           |> Movement.sample_pose()}

        {:early, next, delay} ->
          schedule_player_tick(state, next, delay)
          {:noreply, %{state | simulation_clock: next}}

        :stale ->
          {:noreply, state}
      end
    end)
  end

  def info({:player_tick, _}, state), do: {:noreply, state}

  def info(:publish_movement, state) do
    Valimc.Connection.guard_connection(state, fn ->
      if state.phase == :play do
        Process.send_after(self(), :publish_movement, 50)

        state =
          Movement.update_player_input(
            ItemUse.publish_equipment(state),
            PlayerInput.tick(state.player.input)
          )
          |> Movement.start_motion()
          |> Movement.sample_pose()
          |> Replication.chunk_tick()

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

        {border_view, border_packets} =
          BorderReplication.reconcile(state.border_view, Valimc.World.Clock.border())

        state =
          Replication.emit_peer_packets(
            %{state | border_view: border_view},
            border_packets,
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

  def info(:send_chunks, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Replication.stream_chunks(state)}
      end)

  # Region events of a dimension the player no longer is in are stale (VMC-026b);
  # those of its own dimension apply as they are.
  def info({:event, {:in_dimension, dimension, event}}, state) do
    if dimension == Valimc.Dimension.current(),
      do:
        Valimc.Connection.guard_connection(state, fn ->
          {:noreply, Events.event(state, event)}
        end),
      else: {:noreply, state}
  end

  # An untagged region event is the overworld's, stale for a player elsewhere.
  def info({:event, event}, state) do
    if is_tuple(event) and elem(event, 0) in @region_events and
         Valimc.Dimension.current() != :overworld,
       do: {:noreply, state},
       else:
         Valimc.Connection.guard_connection(state, fn ->
           {:noreply, Events.event(state, event)}
         end)
  end

  # Overload is signalled, not killed, so terminate/2 still saves and releases jobs.
  def info({:EXIT, _from, {:shutdown, :overloaded} = reason}, state),
    do: {:stop, reason, state}

  def info({:EXIT, _from, :normal}, state), do: {:noreply, state}

  def info({:EXIT, _from, reason}, state),
    do: {:stop, {:shutdown, {:linked_exit, reason}}, state}

  def info(message, state) do
    Logger.warning("Connection ignored unexpected message: #{inspect(message, limit: 8)}")
    {:noreply, state}
  end

  # Manual clocks (tests) tick only on explicit messages.
  defp schedule_player_tick(%{player_ticks: :manual}, _next, _delay), do: :ok

  defp schedule_player_tick(_state, next, delay),
    do: Process.send_after(self(), {:player_tick, next.token}, delay)
end
