defmodule Valimc.Player.Transfers do
  @moduledoc "Item transfers a connection starts and recovers: drops, inventory transfers, pickups, experience and recovery delivery (VMC-069)."

  alias Valimc.Session.Jobs
  alias Valimc.Player.Movement

  import Valimc.Net.Codec,
    only: [reject: 2]

  alias Valimc.{
    Inventory,
    PlayerInput,
    PlayerPickupQuery,
    PlayerSnapshot,
    PlayerStore,
    TransferDelivery,
    World
  }

  defguardp inventory_busy(state)
            when state.recovery != nil or state.creative_input.queued > 0 or state.use_save != nil or
                   state.table_job != nil or
                   (is_map_key(state.jobs.active, :placement) and
                      :erlang.map_get(:placement, state.jobs.active).command.mode == :survival)

  defguardp inventory_pending(state)
            when inventory_busy(state) or state.table_closing or state.crafting_repeat != nil

  @doc "Whether an inventory transaction is in flight (commands then refuse to edit it)."
  def inventory_pending?(state) when inventory_pending(state), do: true
  def inventory_pending?(_state), do: false

  def deliver_recovery(state) do
    token = make_ref()

    case TransferDelivery.start(self(), token, state.player.uuid, state.recovery.intent) do
      {:ok, job} -> %{state | recovery: %{state.recovery | stage: :delivery, job: job}}
      error -> recovery_failure(state, error)
    end
  end

  def recovered_inventory(state, snapshot) do
    %{
      snapshot.inventory
      | infinite_materials: state.inventory.infinite_materials,
        state_id: state.inventory.state_id,
        drag: nil
    }
  end

  @doc false
  def new_recovery(mode, stage, intent) do
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

  def recovery_failure(state, result) do
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

  @doc false
  def drop_selected(state, _)
      when inventory_pending(state) or state.save_ref != nil,
      do: Valimc.Player.CreativeInventory.resync_inventory(state)

  def drop_selected(state, all) do
    case Inventory.drop_selected(state.inventory, all) do
      {:ok, _inventory, nil} ->
        Valimc.Player.CreativeInventory.resync_inventory(state)

      {:ok, inventory, stack} ->
        start_inventory_transfer(state, inventory, [stack])

      {:error, _} ->
        Valimc.Player.CreativeInventory.resync_inventory(state)
    end
  end

  def start_inventory_transfer(state, inventory, stacks, crafting \\ nil)

  def start_inventory_transfer(state, _, _, _)
      when inventory_pending(state) or state.save_ref != nil,
      do: Valimc.Player.CreativeInventory.resync_inventory(state)

  def start_inventory_transfer(state, inventory, stacks, crafting) do
    prepare_inventory_transfer(state, inventory, stacks, crafting)
  end

  def start_experience_query(state, views) do
    now = System.monotonic_time(:millisecond)

    if not Jobs.active?(state.jobs, :experience) and not Jobs.active?(state.jobs, :pickup) and
         state.table_job == nil and
         state.table_queued == 0 and pickup_allowed?(state) and now >= state.experience_after do
      {:ok, actor} = PlayerPickupQuery.actor(state.player)

      candidates =
        Enum.filter(views, fn {_, v} ->
          Valimc.World.ExperienceTransfers.contact?(actor.box, v.at)
        end)

      case Enum.min_by(candidates, fn {id, _} -> id end, fn -> nil end) do
        nil ->
          state

        {_, view} ->
          key = World.region_key(view.chunk)

          case World.existing_owner(key) do
            {:ok, {_, epoch} = owner} when epoch == view.epoch ->
              ref = make_ref()
              {x, y, z} = view.at

              request = %{
                kind: :experience,
                permit: <<0::128>>,
                position: {floor(x), floor(y), floor(z)},
                orb_uuid: view.uuid,
                value: view.value,
                consumed: view.consumed,
                before: state.player.progression.experience,
                collector: state.player.entity_id
              }

              intent = %{kind: :container, key: key, request: request}

              PlayerStore.container_candidate(
                state.player_store,
                state.store_fence,
                PlayerSnapshot.capture(state.player, state.inventory),
                intent,
                ref
              )

              {jobs, _job} =
                Jobs.track(state.jobs, :experience, nil,
                  ref: ref,
                  timeout: 500,
                  data: %{
                    stage: :candidate,
                    owner: owner,
                    intent: nil,
                    signature: PlayerPickupQuery.signature(state.player),
                    actor: Map.put(actor, :expires, now + 500)
                  }
                )

              %{state | jobs: jobs, experience_after: now + 100}

            _ ->
              state
          end
      end
    else
      state
    end
  end

  def experience_current?(state, job),
    do:
      pickup_allowed?(state, true) and not Jobs.active?(state.jobs, :pickup) and
        job.signature == PlayerPickupQuery.signature(state.player) and
        System.monotonic_time(:millisecond) < job.actor.expires

  def cancel_experience_query(state) do
    {_job, jobs} = Jobs.cancel(state.jobs, :experience)
    %{state | jobs: jobs}
  end

  # An experience query in flight blocks pickups unless it is the caller's own check.
  def pickup_allowed?(state, own_experience \\ false) do
    (own_experience or not Jobs.active?(state.jobs, :experience)) and state.phase == :play and
      state.life_stage == :alive and
      state.player.living.health.value > 0 and
      state.player.game_mode.current in [:survival, :adventure, :creative] and
      PlayerInput.loaded?(state.player.input) and not state.teleport_pending and
      not inventory_pending(state) and state.save_ref == nil and
      not Jobs.active?(state.jobs, :placement) and
      state.pose_checked == Movement.pose_signature(state)
  end

  def start_pickup_query(%{jobs: jobs} = state, _) when is_map_key(jobs.active, :pickup),
    do: state

  def start_pickup_query(state, views) when map_size(views) == 0, do: state

  def start_pickup_query(state, views) do
    if pickup_allowed?(state) do
      {:ok, actor} = PlayerPickupQuery.actor(state.player)

      case PlayerPickupQuery.candidate(views, actor.box, state.pickup_cursor) do
        nil ->
          state

        {id, view} ->
          state = %{state | pickup_cursor: id}

          case PlayerPickupQuery.start(actor, view) do
            {:ok, task} ->
              {jobs, _job} =
                Jobs.track(state.jobs, :pickup, task,
                  timeout: 500,
                  data: %{signature: PlayerPickupQuery.signature(state.player)}
                )

              %{state | jobs: jobs}

            _ ->
              state
          end
      end
    else
      state
    end
  end

  def prepare_pickup(state, job, reservation) do
    result =
      with true <- pickup_allowed?(state),
           true <- job.signature == PlayerPickupQuery.signature(state.player),
           {:ok, _next, remainder, _callback} <-
             Inventory.pickup_stack(state.inventory, reservation.grant.before),
           true <- remainder != reservation.grant.before do
        snapshot = PlayerSnapshot.capture(state.player, state.inventory)

        intent = %{
          kind: :pickup,
          key: reservation.key,
          request: Map.put(reservation.grant, :remainder, remainder)
        }

        ref = make_ref()

        recovery = %{
          new_recovery(:play, :prepare, nil)
          | ref: ref,
            plan: %{
              key: reservation.key,
              records: [],
              inventory: state.inventory,
              intent: intent,
              snapshot: snapshot
            }
        }

        PlayerStore.prepare_pickup(state.player_store, state.store_fence, snapshot, intent, ref)
        {:ok, %{state | recovery: recovery}}
      else
        _ -> :unavailable
      end

    case result do
      {:ok, next} ->
        next

      _ ->
        PlayerPickupQuery.release(reservation, state.player.uuid)
        state
    end
  end

  def cancel_pickup_query(state) do
    {_job, jobs} = Jobs.cancel(state.jobs, :pickup)
    %{state | jobs: jobs}
  end

  def prepare_inventory_transfer(state, inventory, stacks, crafting \\ nil) do
    case Valimc.PlayerDrops.records(state.player, stacks, :directed) do
      {:ok, key, records} -> prepare_drop_transfer(state, inventory, key, records, crafting)
      {:error, _} -> Valimc.Player.CreativeInventory.resync_inventory(state)
    end
  end

  def prepare_drop_transfer(state, inventory, key, records, crafting) do
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

    Valimc.Player.CreativeInventory.resync_inventory(%{state | recovery: recovery})
  end
end
