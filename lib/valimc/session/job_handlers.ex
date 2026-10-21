defmodule Valimc.Session.JobHandlers do
  @moduledoc "Per-kind results, failures and deadlines of the connection's worker jobs (Session.Jobs) (VMC-069)."

  alias Valimc.Protocol.{
    Packets
  }

  alias Valimc.Player.Placement
  alias Valimc.Player.CreativeInventory
  alias Valimc.Player.Transfers
  alias Valimc.Player.Mining
  alias Valimc.Session.Replication
  alias Valimc.Player.Movement
  alias Valimc.Player.Vitals

  import Valimc.Net.Codec,
    only: [send_packets: 2, reject: 2]

  alias Valimc.{
    PlayerKinetics,
    PlayerMotion,
    PlayerMiningQuery,
    PlayerSnapshot,
    PlayerStore,
    World
  }

  def job_result(:pose, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def job_result(:pickup, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
      case result do
        {:ok, reservation} -> {:noreply, Transfers.prepare_pickup(state, job, reservation)}
        _ -> {:noreply, state}
      end
    end)
  end

  def job_result(:mining, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def job_result(:placement, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
      case result do
        {:reserved, reservation} ->
          {:noreply, Placement.prepare_survival_placement(state, job.command, reservation)}

        {:ok, outcome, after_ack} ->
          state =
            if job.command.body == nil, do: CreativeInventory.resync_inventory(state), else: state

          state =
            if job.command[:kind] == :ignite,
              do: Valimc.Portal.Items.used(state, job.command, outcome),
              else: state

          send_packets(state, [Packets.ack(job.command.request.sequence) | after_ack])
          {:noreply, state |> Vitals.continue_life() |> Placement.drain_placements()}

        _ ->
          reject(state, "Block interaction unavailable; please reconnect")
      end
    end)
  end

  def job_result(:motion, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
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

  def job_result(:experience, job, result, state) do
    Valimc.Connection.guard_connection(state, fn ->
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

  # A portal's destination (VMC-026b2): travel there.
  def job_result(:portal, _job, result, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Valimc.Player.Portals.arrived(state, result)}
      end)

  def job_down(:motion, _job, _reason, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Movement.correct_motion(state, :movement_geometry_corrections)}
      end)

  def job_down(:placement, _job, _reason, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        reject(state, "Block interaction failed; please reconnect")
      end)

  def job_down(:mining, _job, _reason, state),
    do:
      Valimc.Connection.guard_connection(state, fn -> {:noreply, Mining.cancel_mining(state)} end)

  def job_down(kind, _job, _reason, state) when kind in [:pose, :pickup, :experience, :portal],
    do: {:noreply, state}

  def job_timeout(:motion, _job, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        {:noreply, Movement.correct_motion(state, :movement_worker_deadline_corrections)}
      end)

  def job_timeout(:placement, _job, state),
    do:
      Valimc.Connection.guard_connection(state, fn ->
        reject(state, "Block interaction timed out; please reconnect")
      end)

  def job_timeout(:mining, _job, state),
    do:
      Valimc.Connection.guard_connection(state, fn -> {:noreply, Mining.cancel_mining(state)} end)

  def job_timeout(_kind, _job, state), do: {:noreply, state}
end
