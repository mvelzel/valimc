defmodule Valimc.World.RegionData do
  @moduledoc "One storage resource's data and operations, executed by its owning process."
  alias Valimc.World.{
    BlockBatch,
    Chunk,
    CookingRuntime,
    CookingOrbRuntime,
    CookingOrbDelivery,
    ContainerRequest,
    ContainerTransfers,
    ContainerPermits,
    ContainerViewers,
    ContainerLifecycle,
    ContainerSpills,
    ColumnIndex,
    Items,
    ItemHandoffs,
    ItemHandoffDelivery,
    ItemReceipts,
    ItemMerges,
    ItemMergeEscrow,
    ItemMergeInbox,
    ItemMergePermits,
    ItemCrossMergeQuery,
    OwnerItemReceipts,
    ItemTransfers,
    PickupPermits,
    PickupTransfers,
    MiningPermits,
    MiningTransfers,
    PlacementPermits,
    PlacementTransfers,
    Store
  }

  alias Valimc.Protocol.Packets

  defstruct [
    :key,
    :containers,
    :container_permits,
    :container_viewers,
    :cooking_progress,
    :cooking,
    :cooking_orbs,
    :items,
    :item_receipts,
    :pickup_permits,
    :item_merge_permits,
    :item_storage_enabled,
    :item_publication,
    :item_pending,
    :item_handoff,
    :item_simulation,
    :item_simulation_enabled,
    :item_merge_stamp,
    :item_merge_next,
    :item_cross_job,
    :item_cross_next,
    :item_cross_stamp,
    :item_cross_scan_stamp,
    :item_cross_cursor,
    :item_cross_retry,
    :item_resting,
    :item_motion_generation,
    :item_saved_generation,
    :item_checkpoint,
    :item_checkpoint_timer,
    :mining_permits,
    :placement_permits,
    :store,
    :store_lease,
    :store_monitor,
    :edits,
    :by_chunk,
    :column_index,
    :cache,
    :jobs,
    :versions,
    :revision,
    :dirty,
    :saving,
    :save_timer
  ]

  def load(key) do
    {:ok, store, store_lease} = Store.open(key)
    store_monitor = Process.monitor(store)
    edits = Store.load(store)

    containers =
      case Store.load_containers(store) do
        {:ok, containers} -> containers
        {:error, reason} -> exit({:container_load_failed, reason})
      end

    {items, receipts, persistent} =
      case Store.load_items(store) do
        {:ok, %{records: records, receipts: receipts, ledger: ledger, persistent: persistent}} ->
          case Items.restore(key, records, ledger) do
            {:ok, items} -> {items, receipts, persistent}
            {:error, reason} -> exit({:item_load_failed, reason})
          end

        {:error, reason} ->
          exit({:item_load_failed, reason})
      end

    publication = :ets.new(:region_items, [:set, :protected, read_concurrency: true])
    :ets.insert(publication, [{:items, items.views}, {:block_fence, items.epoch, 0}])

    by_chunk =
      Enum.reduce(edits, %{}, fn {{x, _, z} = pos, block}, acc ->
        chunk = Valimc.World.chunk_key(x, z)
        Map.update(acc, chunk, %{pos => block}, &Map.put(&1, pos, block))
      end)

    save_timer = Process.send_after(self(), {:resource, items.epoch, :save}, 30_000)

    %__MODULE__{
      key: key,
      items: items,
      item_receipts: receipts,
      containers: containers,
      container_permits: %ContainerPermits{},
      container_viewers: %ContainerViewers{},
      cooking_progress: %{},
      cooking: %CookingRuntime{enabled: Valimc.config(:cooking_simulation)},
      cooking_orbs: %CookingOrbRuntime{},
      pickup_permits: PickupPermits.new(),
      item_merge_permits: ItemMergePermits.new(),
      item_storage_enabled: persistent,
      item_publication: publication,
      item_pending: nil,
      item_handoff: nil,
      item_simulation: nil,
      item_simulation_enabled: Valimc.config(:item_simulation),
      item_merge_stamp: nil,
      item_merge_next: nil,
      item_cross_job: nil,
      item_cross_next: nil,
      item_cross_stamp: nil,
      item_cross_scan_stamp: nil,
      item_cross_cursor: nil,
      item_cross_retry: false,
      item_resting: %{},
      item_motion_generation: 0,
      item_saved_generation: 0,
      item_checkpoint: nil,
      item_checkpoint_timer: nil,
      mining_permits: %MiningPermits{},
      placement_permits: %PlacementPermits{},
      store: store,
      store_lease: store_lease,
      store_monitor: store_monitor,
      edits: edits,
      by_chunk: by_chunk,
      column_index: ColumnIndex.restore(edits),
      cache: %{},
      jobs: %{},
      versions: %{},
      revision: 0,
      dirty: false,
      saving: false,
      save_timer: save_timer
    }
    |> resume_item_handoff()
  end

  def item_tick(state, now) do
    if state.item_simulation_enabled and state.item_pending == nil do
      {items, expired} = Items.age(state.items)
      state = remember_item_counters(state, items)
      state = %{state | item_resting: Map.take(state.item_resting, Map.keys(items.entries))}

      if expired == [] do
        state = start_item_cross_merging(state, now)
        state = start_item_simulation(state, now)
        if state.item_simulation == nil, do: start_item_merging(state, now), else: state
      else
        items =
          Enum.reduce(expired, items, fn {epoch, id, revision}, acc ->
            {:ok, next} = Items.remove(acc, epoch, id, revision)
            next
          end)

        {:noreply, state} = commit_items(items, :ok, nil, state)
        state
      end
    else
      state
    end
  end

  def cooking_tick(%{cooking: runtime} = state, now) do
    cond do
      not runtime.enabled or not state.item_storage_enabled or runtime.job != nil or
          state.item_pending != nil ->
        state

      runtime.dirty and now >= runtime.checkpoint_at and
          (not CookingRuntime.due?(runtime, state.containers, state.edits, state.items, now) or
             (runtime.seen == nil and is_integer(runtime.retry_at) and now < runtime.retry_at)) ->
        checkpoint_cooking(state)

      is_integer(runtime.retry_at) and now < runtime.retry_at and runtime.seen == nil ->
        state

      CookingRuntime.due?(runtime, state.containers, state.edits, state.items, now) ->
        start_cooking_plan(state, now)

      true ->
        state
    end
  end

  defp checkpoint_cooking(state) do
    token = make_ref()

    Store.commit_containers(
      state.store,
      state.store_lease,
      state.containers,
      {self(), state.items.epoch},
      token
    )

    pending = %{
      kind: :cooking_checkpoint,
      phase: :writing,
      token: token,
      from: nil,
      timer: send_after(state, {:item_commit_deadline, token}, 5000)
    }

    Valimc.Metrics.add(:cooking_checkpoints)
    %{state | item_pending: pending}
  end

  defp start_cooking_plan(state, now) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    containers = state.containers
    items = state.items
    edits = state.edits
    key = state.key
    selection = CookingRuntime.selection(state.cooking, containers, edits, items, now)
    blocked = state.cooking.blocked

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result = CookingRuntime.plan(containers, items, key, edits, selection, blocked)
           send(owner, {:resource, epoch, {:cooking_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        job = %{
          worker: worker,
          token: token,
          monitor: Process.monitor(worker),
          timer: send_after(state, {:cooking_deadline, token}, 500),
          containers: containers,
          items: items
        }

        Valimc.Metrics.add(:cooking_batches)
        %{state | cooking: %{state.cooking | job: job}}

      {:error, _} ->
        Valimc.Metrics.add(:cooking_busy)
        %{state | cooking: %{state.cooking | seen: nil, retry_at: now + 100}}
    end
  end

  defp accept_cooking_plan(state, job, plan) do
    current =
      state.item_pending == nil and state.containers == job.containers and
        Enum.all?(plan.expected, fn {position, block} ->
          Chunk.block_at(state.edits, position) == block
        end)

    with true <- current,
         {:ok, items} <- Items.merge_created(state.items, job.items, plan.items) do
      plan = %{plan | items: items}

      if plan.changes == %{},
        do: finish_cooking(state, plan, false),
        else: commit_cooking(state, plan)
    else
      _ ->
        Valimc.Metrics.add(:cooking_stale)
        state
    end
  end

  defp commit_cooking(state, plan) do
    result =
      if plan.batch do
        if Enum.all?(plan.batch.edits, fn {position, block} ->
             CookingRuntime.lit_change?(Chunk.block_at(state.edits, position), block)
           end), do: build_block_proposal(state, plan.batch), else: {:error, :invalid_cooking_lit}
      else
        {:ok, nil}
      end

    case result do
      {:ok, proposal} ->
        token = make_ref()

        Store.commit_mining(
          state.store,
          state.store_lease,
          %{
            edits: if(proposal, do: proposal.edits, else: state.edits),
            changes: plan.changes,
            items: plan.items,
            receipts: state.item_receipts,
            containers: plan.containers
          },
          {self(), state.items.epoch},
          token
        )

        pending = %{
          kind: :cooking_batch,
          phase: :writing,
          token: token,
          from: nil,
          timer: send_after(state, {:item_commit_deadline, token}, 5000),
          plan: plan,
          proposal: proposal
        }

        Valimc.Metrics.add(:cooking_commits)
        %{state | item_pending: pending}

      {:error, _} ->
        Valimc.Metrics.add(:cooking_plan_failures)

        %{
          state
          | cooking: %{
              state.cooking
              | seen: nil,
                retry_at: System.monotonic_time(:millisecond) + 1000
            }
        }
    end
  end

  defp finish_cooking(state, plan, durable) do
    now = System.monotonic_time(:millisecond)

    state =
      if durable and plan.batch,
        do: publish_blocks(state, plan.batch, plan.proposal, false, true),
        else: state

    runtime =
      CookingRuntime.accepted(state.cooking, plan, plan.containers, state.edits, plan.items, now)

    runtime =
      cond do
        durable ->
          %{runtime | dirty: false}

        plan.changed != [] and not runtime.dirty ->
          %{runtime | dirty: true, checkpoint_at: now + 1000}

        true ->
          runtime
      end

    :ets.insert(state.item_publication, {:items, plan.items.views})

    state = %{
      state
      | containers: plan.containers,
        items: plan.items,
        cooking: runtime,
        cooking_progress: Map.take(state.cooking_progress, Map.keys(plan.containers.entries)),
        container_permits:
          ContainerPermits.invalidate(state.container_permits, Map.new(plan.content, &{&1, nil}))
    }

    state =
      if durable, do: %{state | item_saved_generation: state.item_motion_generation}, else: state

    state = Enum.reduce(plan.content, state, &notify_container_changed(&2, &1))

    state =
      Enum.reduce(plan.changed, state, fn position, state ->
        generation = Map.get(state.cooking_progress, position, 0) + 1

        {viewers, notices} =
          ContainerViewers.progressed(state.container_viewers, position, generation)

        for {pid, ref, progress} <- notices,
            do:
              Valimc.Connection.deliver(
                pid,
                {:container_progress, {self(), state.items.epoch}, ref, position, progress}
              )

        %{
          state
          | container_viewers: viewers,
            cooking_progress: Map.put(state.cooking_progress, position, generation)
        }
      end)

    if not durable and state.cooking.dirty and now >= state.cooking.checkpoint_at,
      do: checkpoint_cooking(state),
      else: state
  end

  defp start_item_cross_merging(state, now) do
    if state.item_cross_job == nil and state.item_storage_enabled and
         state.items.ledger.outgoing == nil and
         (state.item_cross_next == nil or now >= state.item_cross_next) do
      state = %{state | item_cross_next: now + 200}

      case ItemCrossMergeQuery.scene(state.key, state.items.views) do
        nil ->
          %{
            state
            | item_cross_stamp: nil,
              item_cross_scan_stamp: nil,
              item_cross_cursor: nil,
              item_cross_retry: false
          }

        %{stamp: stamp} = scene ->
          cond do
            stamp == state.item_cross_stamp ->
              state

            scene.targets == [] ->
              %{
                state
                | item_cross_stamp: stamp,
                  item_cross_scan_stamp: nil,
                  item_cross_cursor: nil,
                  item_cross_retry: false
              }

            true ->
              # Physical changes cannot keep resetting a crowded moving scene to
              # its first batch. Finish the cycle, then rescan changed observations.
              cursor = state.item_cross_cursor
              scan_stamp = state.item_cross_scan_stamp || stamp
              retry = state.item_cross_retry
              token = make_ref()

              case ItemCrossMergeQuery.start(
                     self(),
                     state.items.epoch,
                     token,
                     state.key,
                     scene,
                     cursor
                   ) do
                {:ok, worker, monitor} ->
                  Valimc.Metrics.add(:item_cross_jobs)

                  job = %{
                    worker: worker,
                    monitor: monitor,
                    token: token,
                    stamp: stamp,
                    scan_stamp: scan_stamp,
                    retry: retry,
                    timer: send_after(state, {:item_cross_deadline, token}, 750)
                  }

                  %{state | item_cross_job: job}

                {:error, _} ->
                  Valimc.Metrics.add(:item_cross_busy)
                  state
              end
          end
      end
    else
      state
    end
  end

  defp start_item_merging(state, now) do
    if state.item_storage_enabled and map_size(state.items.entries) >= 2 and
         (state.item_merge_next == nil or now >= state.item_merge_next) do
      stamp = Map.new(state.items.entries, fn {id, entry} -> {id, entry.physical_revision} end)
      state = %{state | item_merge_next: now + 200}

      if stamp == state.item_merge_stamp do
        state
      else
        case plan_item_change(:item_merge_auto, {nil, now + 250}, nil, state) do
          {:noreply, next} ->
            Valimc.Metrics.add(:item_merge_jobs)
            %{next | item_merge_stamp: stamp}

          {:reply, _, next} ->
            Valimc.Metrics.add(:item_merge_busy)
            next
        end
      end
    else
      state
    end
  end

  defp remember_item_counters(state, items) do
    if items == state.items do
      state
    else
      :ets.insert(state.item_publication, {:items, items.views})
      generation = state.item_motion_generation + 1

      schedule_item_checkpoint(%{
        state
        | items: items,
          item_motion_generation: generation,
          item_saved_generation:
            if(state.item_storage_enabled, do: state.item_saved_generation, else: generation)
      })
    end
  end

  defp start_item_simulation(%{item_simulation: nil} = state, now) do
    inputs =
      for {id, entry} <- state.items.entries, not resting_current?(state, id) do
        %{
          id: id,
          revision: entry.revision,
          position: {entry.entity.x, entry.entity.y, entry.entity.z},
          motion: entry.motion,
          physical_revision: entry.physical_revision
        }
      end

    if inputs == [] do
      state
    else
      token = make_ref()

      case Valimc.ItemSimulation.start(self(), state.items.epoch, token, inputs) do
        {:ok, job} ->
          Valimc.Metrics.add(:item_simulation_jobs)
          timer = send_after(state, {:item_simulation_deadline, token}, 350)
          %{state | item_simulation: Map.merge(job, %{timer: timer, deadline: now + 350})}

        {:error, _} ->
          Valimc.Metrics.add(:item_simulation_busy)
          state
      end
    end
  end

  defp start_item_simulation(state, _), do: state

  defp resting_current?(state, id) do
    case state.item_resting[id] do
      {version, fences} ->
        version == state.items.entries[id].physical_revision and
          Valimc.World.item_frame_current?(fences)

      nil ->
        false
    end
  end

  def handle_call({:create_item, epoch, stack, position}, from, state) do
    item_request(epoch, from, state, fn ->
      Items.create(state.items, state.key, stack, position)
    end)
  end

  def handle_call({:replace_item, epoch, id, revision, stack}, from, state),
    do:
      item_request(epoch, from, state, fn ->
        Items.replace(state.items, epoch, id, revision, stack)
      end)

  def handle_call({:remove_item, epoch, id, revision}, from, state),
    do: item_request(epoch, from, state, fn -> Items.remove(state.items, epoch, id, revision) end)

  def handle_call({:reserve_pickup, epoch, actor, item_uuid, deadline}, from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :expired_item_step}, state}

      true ->
        case PickupPermits.issue(
               state.pickup_permits,
               state.item_receipts,
               state.items,
               actor,
               item_uuid,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, grant} ->
            {:reply, {:ok, grant}, %{state | pickup_permits: permits}}

          {:error, :pickup_receipt_slot_required} ->
            with {:ok, {_, id, _}} <- Items.find(state.items, item_uuid),
                 true <- Valimc.Physics.ItemPickup.eligible?(actor, state.items.entries[id]) do
              actor = Map.take(actor, [:uuid, :entity_id, :box, :game_mode, :health, :passenger])
              plan_item_change(:pickup_admission, {actor, item_uuid, deadline}, from, state)
            else
              _ -> {:reply, {:error, :pickup_not_available}, state}
            end

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:pickup_transfer, epoch, request}, from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      true ->
        grant =
          case request do
            %{permit: token} -> state.pickup_permits.entries[token]
            _ -> nil
          end

        {permits, eligible} =
          PickupPermits.consume(
            state.pickup_permits,
            state.items,
            request,
            System.monotonic_time(:millisecond)
          )

        # This owner admits the decision now and freezes item mutations while
        # planning/persisting. Expiry after admission cannot change its ordering.
        effect = pickup_effect(state.items, request, grant, eligible)

        case plan_item_change(:item_pickup, {request, eligible, effect}, from, state) do
          {:noreply, next} -> {:noreply, %{next | pickup_permits: permits}}
          reply -> reply
        end
    end
  end

  def handle_call({:item_merge_donor, epoch, uuid, recipient}, _, state) do
    with :ok <- cross_merge_ready(state, epoch),
         true <- state.items.ledger.outgoing == nil,
         {:ok, {^epoch, id, _}} <- Items.find(state.items, uuid) do
      entry = state.items.entries[id]

      record =
        entry.entity
        |> Map.take([:uuid, :x, :y, :z])
        |> Map.put(:stack, entry.stack)
        |> Map.put(
          :motion,
          Map.get(entry, :motion, %Valimc.ItemMotionState{no_gravity: entry.no_gravity})
        )

      view = state.items.views[id]

      proposal = %{
        source: state.key,
        sequence: state.items.ledger.sequence + 1,
        donor: record,
        donor_generation: Map.get(state.items.ledger.generations, uuid, 0),
        recipient_uuid: recipient
      }

      fence = %{
        key: state.key,
        owner: {self(), epoch},
        id: id,
        uuid: uuid,
        versions: view.physical_revision,
        expires_at: System.monotonic_time(:millisecond) + 250
      }

      {:reply, {:ok, proposal, fence}, state}
    else
      _ -> {:reply, {:error, :item_merge_not_available}, state}
    end
  end

  def handle_call({:item_merge_counters, epoch, request, source_fence}, from, state) do
    with :ok <- cross_merge_ready(state, epoch) do
      {permits, permitted} =
        ItemMergePermits.consume(
          state.item_merge_permits,
          state.items,
          request,
          System.monotonic_time(:millisecond)
        )

      valid =
        permitted and
          match?(
            %{key: key, uuid: uuid} when key == request.source and uuid == request.donor.uuid,
            source_fence
          ) and
          Valimc.World.item_observation_current?(source_fence)

      # The source owner authorized this snapshot. Its publication only fences it;
      # this admission orders the counter effect before later source changes.
      case plan_item_change(:cross_merge_counters, {request, valid}, from, state) do
        {:noreply, next} -> {:noreply, %{next | item_merge_permits: permits}}
        reply -> reply
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:reserve_item_merge, epoch, proposal, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    source =
      case proposal do
        %{source: source} -> source
        _ -> nil
      end

    with :ok <- cross_merge_ready(state, epoch),
         true <- is_integer(deadline) and now < deadline,
         :ok <- ItemMergePermits.available?(state.item_merge_permits, source, now) do
      plan_item_change(:cross_merge_admission, {proposal, deadline}, from, state)
    else
      false -> {:reply, {:error, :expired_item_step}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:prepare_item_merge, epoch, request}, from, state) do
    with :ok <- cross_merge_ready(state, epoch),
         do: plan_item_change(:cross_merge_out, request, from, state),
         else: (error -> {:reply, error, state})
  end

  def handle_call({:apply_item_merge, epoch, request}, from, state) do
    with :ok <- cross_merge_ready(state, epoch) do
      {permits, allowed} =
        ItemMergePermits.consume(
          state.item_merge_permits,
          state.items,
          request,
          System.monotonic_time(:millisecond)
        )

      case plan_item_change(:cross_merge_in, {request, allowed}, from, state) do
        {:noreply, next} -> {:noreply, %{next | item_merge_permits: permits}}
        reply -> reply
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:owner_item_receipt, epoch, source}, _, state) do
    result =
      cond do
        epoch != state.items.epoch -> {:error, :stale_region}
        not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
        not Map.has_key?(state.items.ledger.incoming, source) -> {:error, :missing_item_receipt}
        true -> {:ok, {state.key, state.items.ledger.incoming[source]}}
      end

    {:reply, result, state}
  end

  def handle_call({:merge_items, epoch, pairs, deadline}, from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :expired_item_step}, state}

      true ->
        plan_item_change(:item_merge, {pairs, deadline}, from, state)
    end
  end

  def handle_call({:advance_items, epoch, steps, deadline}, from, state) do
    item_request(epoch, from, state, fn ->
      if is_integer(deadline) and System.monotonic_time(:millisecond) < deadline,
        do: Items.advance(state.items, state.key, epoch, steps),
        else: {:error, :expired_item_step}
    end)
  end

  def handle_call({:publish_item_motion, epoch, steps, deadline}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :expired_item_step}, state}

      true ->
        case Items.advance(state.items, state.key, epoch, steps) do
          {:ok, items, handles} ->
            handles =
              Enum.map(handles, fn {epoch, id, revision} -> {self(), epoch, id, revision} end)

            if items == state.items do
              {:reply, {:ok, handles}, state}
            else
              :ets.insert(state.item_publication, {:items, items.views})
              generation = state.item_motion_generation + 1

              next = %{
                state
                | items: items,
                  item_motion_generation: generation,
                  item_saved_generation:
                    if(state.item_storage_enabled,
                      do: state.item_saved_generation,
                      else: generation
                    )
              }

              {:reply, {:ok, handles}, schedule_item_checkpoint(next)}
            end

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:item_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      true ->
        plan_transfer(transfer, from, state)
    end
  end

  def handle_call({:handoff_items, epoch, destination, steps, deadline}, from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      state.items.ledger.outgoing != nil ->
        {:reply, {:error, :item_handoff_busy}, state}

      not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :expired_item_step}, state}

      true ->
        plan_item_change(:item_handoff_out, {destination, steps, deadline}, from, state)
    end
  end

  def handle_call({:cooking_orb_spawn, epoch, bytes, deadline}, from, state),
    do: CookingOrbRuntime.adopt(state, epoch, bytes, deadline, from)

  def handle_call({:item_handoff, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> plan_item_change(:item_handoff_in, transfer, from, state)
    end
  end

  def handle_call({:reserve_mining, epoch, positions}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not valid_block_query?(positions, :any) or positions == [] ->
        {:reply, {:error, :invalid_mining_reservation}, state}

      not Enum.all?(positions, fn {x, y, z} ->
        Chunk.valid_y?(y) and Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key
      end) ->
        {:reply, {:error, :wrong_region}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        blocks = Map.new(positions, &{&1, Chunk.block_at(state.edits, &1)})

        case MiningPermits.reserve(
               state.mining_permits,
               blocks,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, token} ->
            {:reply, {:ok, %{permit: token, expected: blocks}},
             %{state | mining_permits: permits}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:renew_mining, epoch, permit}, _from, state) do
    if epoch == state.items.epoch do
      case MiningPermits.renew(state.mining_permits, permit, System.monotonic_time(:millisecond)) do
        {:ok, permits, blocks} ->
          {:reply, {:ok, blocks}, %{state | mining_permits: permits}}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :stale_owner}, state}
    end
  end

  def handle_call({:release_mining, epoch, permit}, _from, state) do
    if epoch == state.items.epoch,
      do:
        {:reply, :ok,
         %{state | mining_permits: MiningPermits.remove(state.mining_permits, permit)}},
      else: {:reply, {:error, :stale_owner}, state}
  end

  def handle_call({:mining_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> plan_block_transfer(:mining, transfer, from, state)
    end
  end

  def handle_call({:reserve_placement, epoch, revision, expected}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not is_map(expected) or map_size(expected) not in 1..2 ->
        {:reply, {:error, :invalid_placement_reservation}, state}

      not valid_block_query?(Map.keys(expected), revision) ->
        {:reply, {:error, :invalid_placement_reservation}, state}

      revision != state.revision ->
        {:reply, {:error, :stale_revision}, state}

      not Enum.all?(expected, fn {{x, y, z}, block} ->
        Chunk.valid_y?(y) and Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key and
            Chunk.block_at(state.edits, {x, y, z}) == block
      end) ->
        {:reply, {:error, :placement_context_changed}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        case PlacementPermits.reserve(
               state.placement_permits,
               expected,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, token} ->
            {:reply, {:ok, %{permit: token, expected: expected}},
             %{state | placement_permits: permits}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:release_placement, epoch, permit}, _from, state) do
    if epoch == state.items.epoch,
      do:
        {:reply, :ok,
         %{state | placement_permits: PlacementPermits.remove(state.placement_permits, permit)}},
      else: {:reply, {:error, :stale_owner}, state}
  end

  def handle_call({:placement_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> plan_block_transfer(:placement, transfer, from, state)
    end
  end

  def handle_call({:find_item, epoch, uuid}, _from, state) do
    result =
      if epoch == state.items.epoch,
        do: Items.find(state.items, uuid),
        else: {:error, :stale_region}

    reply =
      case result do
        {:ok, {epoch, id, revision}} -> {:ok, {self(), epoch, id, revision}}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:recover_container_transfer, epoch, request}, from, state) do
    container_request(state, epoch, fn -> start_container_recovery(state, request, from) end)
  end

  def handle_call({:container_transfer, epoch, request}, from, state) do
    container_request(state, epoch, fn ->
      containers = state.containers
      permits = state.container_permits
      key = state.key
      block = container_block(state, request)

      start_container_work(state, from, :deliver, container_position(request), fn ->
        with {:ok, digest} <- ContainerRequest.digest(key, request),
             {:ok, reserved, _} <- ContainerTransfers.reserve(containers, request.source) do
          {permits, eligible} =
            ContainerPermits.consume(
              permits,
              request,
              digest,
              System.monotonic_time(:millisecond)
            )

          eligible = eligible and container_block_matches?(request, block)

          case ContainerTransfers.plan(reserved, key, request, eligible) do
            {:ok, decision} -> {:ok, Map.put(decision, :permits, permits)}
            error -> error
          end
        end
      end)
    end)
  end

  def handle_call({:admit_container_transfer, epoch, request, actor}, from, state) do
    container_request(state, epoch, fn ->
      case container_access(state, request, actor) do
        :ok ->
          containers = state.containers
          key = state.key

          start_container_work(state, from, {:admit, actor}, container_position(request), fn ->
            request = %{request | permit: :crypto.strong_rand_bytes(16)}

            with {:ok, digest} <- ContainerRequest.digest(key, request),
                 {:ok, entry} <- Valimc.World.Containers.observe(containers, request.position),
                 true <- ContainerRequest.matches_entry?(request, entry),
                 {:ok, reserved, _} <- ContainerTransfers.reserve(containers, request.source),
                 {:ok, _} <- Valimc.World.Containers.encode(key, reserved),
                 do: {:ok, %{containers: reserved, result: {:admitted, request, digest}}},
                 else: (_ -> {:error, :invalid_container_admission})
          end)

        error ->
          {:reply, error, state}
      end
    end)
  end

  def handle_call({:container_transfer_receipt, epoch, source}, _from, state) do
    result =
      cond do
        epoch != state.items.epoch -> {:error, :stale_region}
        not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
        not (is_binary(source) and byte_size(source) == 16) -> {:error, :invalid_transfer_source}
        state.containers.receipts[source] == nil -> {:error, :missing_container_receipt}
        true -> {:ok, {state.key, state.containers.receipts[source]}}
      end

    {:reply, result, state}
  end

  def handle_call({:item_transfer_receipt, epoch, source}, _from, state) do
    result =
      cond do
        epoch != state.items.epoch -> {:error, :stale_region}
        not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
        not (is_binary(source) and byte_size(source) == 16) -> {:error, :invalid_transfer_source}
        state.item_receipts[source] == nil -> {:error, :missing_transfer_receipt}
        true -> {:ok, {state.key, state.item_receipts[source]}}
      end

    {:reply, result, state}
  end

  def handle_call({:chunk, key}, from, state) do
    cond do
      Valimc.World.region_key(key) != state.key ->
        {:reply, {:error, :wrong_region}, state}

      Map.has_key?(state.cache, key) ->
        Valimc.Metrics.add(:chunk_cache_hits)
        {:reply, state.cache[key], state}

      Map.has_key?(state.jobs, key) ->
        Valimc.Metrics.add(:chunk_requests_coalesced)
        jobs = Map.update!(state.jobs, key, &%{&1 | waiters: [from | &1.waiters]})
        {:noreply, %{state | jobs: jobs}}

      true ->
        jobs = Map.put(state.jobs, key, %{waiters: [from], pid: nil, monitor: nil, token: nil})
        {:noreply, start_job(%{state | jobs: jobs}, key)}
    end
  end

  def handle_call({:get_block, position}, _from, state),
    do: {:reply, Chunk.block_at(state.edits, position), state}

  def handle_call({:observe_blocks, epoch, positions, expected_revision}, _from, state) do
    result =
      cond do
        not valid_block_query?(positions, expected_revision) ->
          {:error, :invalid_block_query}

        epoch != state.items.epoch ->
          {:error, :stale_owner}

        expected_revision != :any and expected_revision != state.revision ->
          {:error, :stale_revision}

        Enum.any?(positions, fn {x, _, z} ->
          Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != state.key
        end) ->
          {:error, :wrong_region}

        true ->
          {:ok,
           %{
             owner: {self(), state.items.epoch},
             region: state.key,
             revision: state.revision,
             blocks: Map.new(positions, &{&1, Chunk.block_at(state.edits, &1)})
           }}
      end

    {:reply, result, state}
  end

  def handle_call({:observe_columns, epoch, columns, expected_revision}, _from, state) do
    result =
      cond do
        not valid_column_query?(columns, expected_revision) ->
          {:error, :invalid_column_query}

        epoch != state.items.epoch ->
          {:error, :stale_owner}

        expected_revision != :any and expected_revision != state.revision ->
          {:error, :stale_revision}

        Enum.any?(columns, fn {x, z} ->
          Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != state.key
        end) ->
          {:error, :wrong_region}

        true ->
          {:ok,
           %{
             owner: {self(), state.items.epoch},
             region: state.key,
             revision: state.revision,
             columns: Map.new(columns, &{&1, ColumnIndex.heights(state.column_index, &1)})
           }}
      end

    {:reply, result, state}
  end

  def handle_call({:destroy_block, epoch, revision, position, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      revision != state.revision ->
        {:reply, {:error, :stale_revision}, state}

      not (is_integer(deadline) and now < deadline and deadline <= now + 250) ->
        {:reply, {:error, :expired_destruction}, state}

      true ->
        handle_call({:remove_block, position}, from, state)
    end
  end

  def handle_call({:remove_block, position}, from, state) do
    block = Chunk.block_at(state.edits, position)
    replacement = Valimc.Physics.FluidBlocks.after_removal(block)

    if (Valimc.ChestAccess.single?(block) or Valimc.Physics.CookingBlocks.kind(block) != nil) and
         Map.has_key?(state.containers.entries, position) do
      if state.item_pending != nil do
        {:reply, {:error, :item_storage_busy}, state}
      else
        with {:ok, batch} <- BlockBatch.prepare(%{position => replacement}),
             do: start_container_blocks(state, from, batch, %{position => block}, :ok),
             else: (error -> {:reply, error, state})
      end
    else
      handle_call({:set_block, position, replacement}, from, state)
    end
  end

  def handle_call({:correct_blocks, epoch, positions, connection}, from, state) do
    if is_pid(connection) and valid_block_query?(positions, :any) and length(positions) <= 2 do
      case handle_call({:observe_blocks, epoch, positions, :any}, from, state) do
        {:reply, {:ok, observed}, state} ->
          for {position, block} <- observed.blocks,
              do: Valimc.Connection.deliver(connection, {:block, position, block})

          {:reply, :ok, state}

        error ->
          error
      end
    else
      {:reply, {:error, :invalid_block_query}, state}
    end
  end

  def handle_call({:set_blocks, epoch, revision, %BlockBatch{} = batch}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      revision != state.revision ->
        {:reply, {:error, :stale_revision}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        case block_proposal(state, batch) do
          {:ok, proposal} ->
            next = publish_blocks(state, batch, proposal, true)
            {:reply, {:ok, next.revision}, next}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:place_block, epoch, revision, %BlockBatch{} = batch, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    expected =
      Map.new(batch.edits, fn {position, _} ->
        {position, Chunk.block_at(state.edits, position)}
      end)

    cond do
      not (is_integer(deadline) and deadline > now and deadline <= now + 250 and
               map_size(batch.edits) == 1) ->
        {:reply, {:error, :invalid_or_expired_placement}, state}

      not container_metadata_affected?(state.containers, expected, batch.edits) ->
        handle_call({:set_blocks, epoch, revision, batch}, from, state)

      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      revision != state.revision ->
        {:reply, {:error, :stale_revision}, state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      state.item_pending != nil ->
        {:reply, {:error, :item_storage_busy}, state}

      not isolated_chest_changes?(state, batch) ->
        {:reply, {:error, :unsupported_chest_neighbors}, state}

      true ->
        start_container_blocks(state, from, batch, expected)
    end
  end

  def handle_call({:set_block, {x, y, z} = position, block}, _from, state) do
    key = Valimc.World.chunk_key(x, z)

    cond do
      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      protected_container_change?(state, %{position => block}) ->
        {:reply, {:error, :occupied_container}, state}

      true ->
        if Valimc.World.region_key(key) == state.key and Chunk.valid_y?(y) and block >= 0 and
             block < Valimc.Protocol.Data.block_state_count() and
             (map_size(state.edits) < 131_072 or Map.has_key?(state.edits, position)) do
          state = retire_container_changes(state, %{position => block})
          edits = put_edit(state.edits, position, block)
          local = put_edit(Map.get(state.by_chunk, key, %{}), position, block)

          :ets.insert(
            state.item_publication,
            {:block_fence, state.items.epoch, state.revision + 1}
          )

          Valimc.World.publish(state.key, {:block, position, block})
          Valimc.Metrics.add(:block_edits)

          {:reply, :ok,
           %{
             state
             | edits: edits,
               mining_permits:
                 MiningPermits.invalidate(state.mining_permits, %{position => block}),
               container_permits:
                 ContainerPermits.invalidate(state.container_permits, %{position => block}),
               placement_permits:
                 PlacementPermits.invalidate(state.placement_permits, %{position => block}),
               by_chunk: Map.put(state.by_chunk, key, local),
               column_index: ColumnIndex.update(state.column_index, edits, %{position => block}),
               dirty: true,
               revision: state.revision + 1,
               cache: Map.delete(state.cache, key),
               versions: Map.update(state.versions, key, 1, &(&1 + 1))
           }}
        else
          {:reply, {:error, :invalid_block}, state}
        end
    end
  end

  def handle_call(:flush, _from, %{item_pending: %{kind: kind, phase: :writing}} = state)
      when kind in [:mining, :placement],
      do: {:reply, {:error, :mining_storage_busy}, state}

  def handle_call(:flush, _from, %{item_pending: pending} = state) when pending != nil,
    do: {:reply, {:error, :item_storage_busy}, state}

  def handle_call(:flush, _from, state) do
    with :ok <- flush_item_motion(state), :ok <- flush_cooking(state, state.containers) do
      result = Store.flush(state.store, state.store_lease, state.edits)

      {:reply, result,
       %{
         state
         | dirty: result != :ok,
           item_saved_generation: state.item_motion_generation,
           cooking: %{state.cooking | dirty: result != :ok and state.cooking.dirty}
       }}
    else
      error -> {:reply, error, state}
    end
  end

  defp flush_item_motion(state) do
    if state.item_saved_generation < state.item_motion_generation,
      do: Store.flush_items(state.store, state.store_lease, state.items, state.item_receipts),
      else: :ok
  end

  defp flush_cooking(%{cooking: %{dirty: true}} = state, containers),
    do: Store.flush_containers(state.store, state.store_lease, containers)

  defp flush_cooking(_, _), do: :ok

  defp schedule_item_checkpoint(state) do
    if state.item_saved_generation < state.item_motion_generation and state.item_checkpoint == nil and
         state.item_checkpoint_timer == nil do
      token = make_ref()
      timer = send_after(state, {:item_checkpoint, token}, 1000)
      %{state | item_checkpoint_timer: %{token: token, timer: timer}}
    else
      state
    end
  end

  defp item_request(epoch, from, state, work) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> item_result(work.(), from, state)
    end
  end

  defp item_result({:ok, items, {epoch, id, revision}}, from, state) do
    reply = {:ok, {self(), epoch, id, revision}}

    if items == state.items,
      do: {:reply, reply, state},
      else: commit_items(items, reply, from, state)
  end

  defp item_result({:ok, items}, from, state), do: commit_items(items, :ok, from, state)

  defp item_result({:ok, items, handles}, from, state) when is_list(handles) do
    handles = Enum.map(handles, fn {epoch, id, revision} -> {self(), epoch, id, revision} end)

    if items == state.items,
      do: {:reply, {:ok, handles}, state},
      else: commit_items(items, {:ok, handles}, from, state)
  end

  defp item_result({:error, _} = error, _from, state), do: {:reply, error, state}

  defp commit_items(items, reply, from, state),
    do: commit_items(items, reply, from, state, state.item_receipts)

  defp commit_items(items, reply, from, state, receipts) do
    token = make_ref()
    timer = send_after(state, {:item_commit_deadline, token}, 5000)

    Store.commit_items(
      state.store,
      state.store_lease,
      items,
      receipts,
      {self(), state.items.epoch},
      token
    )

    pending = %{
      phase: :writing,
      token: token,
      timer: timer,
      items: items,
      receipts: receipts,
      reply: reply,
      from: from
    }

    {:noreply, %{state | item_pending: pending}}
  end

  defp plan_transfer(transfer, from, state),
    do: plan_item_change(:item_transfer, transfer, from, state)

  defp container_request(state, epoch, start) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      state.item_pending != nil -> {:reply, {:error, :item_storage_busy}, state}
      true -> start.()
    end
  end

  defp container_block(state, %{position: position}) do
    if valid_block_query?([position], :any) and
         Valimc.World.region_key(Valimc.World.chunk_key(elem(position, 0), elem(position, 2))) ==
           state.key,
       do: Chunk.block_at(state.edits, position),
       else: nil
  end

  defp container_block(_, _), do: nil

  defp container_position(%{position: position}), do: position
  defp container_position(_), do: nil

  defp container_access(
         state,
         %{
           source: source,
           position: position,
           rows: 3,
           inventory: %Valimc.Inventory{} = inventory
         } =
           request,
         %{uuid: source, mode: mode} = actor
       ) do
    if inventory.infinite_materials == (mode == :creative),
      do:
        Valimc.ChestAccess.authorize(
          container_block(state, request),
          position,
          actor,
          System.monotonic_time(:millisecond)
        ),
      else: {:error, :invalid_container_context}
  end

  defp container_access(
         state,
         %{
           source: source,
           kind: kind,
           position: position,
           inventory: %Valimc.Inventory{} = inventory
         } = request,
         %{uuid: source, mode: mode} = actor
       ) do
    block = container_block(state, request)

    if inventory.infinite_materials == (mode == :creative) and
         Valimc.Physics.CookingBlocks.kind(block) == kind,
       do:
         Valimc.CookingOpening.authorize_action(
           block,
           position,
           actor,
           System.monotonic_time(:millisecond)
         ),
       else: {:error, :invalid_container_context}
  end

  defp container_access(_, _, _), do: {:error, :invalid_container_context}

  defp container_block_matches?(%{rows: _}, block), do: Valimc.ChestAccess.single?(block)

  defp container_block_matches?(%{kind: kind}, block),
    do: Valimc.Physics.CookingBlocks.kind(block) == kind

  defp container_block_matches?(_, _), do: false

  defp start_container_recovery(state, request, from) do
    containers = state.containers
    key = state.key

    start_container_work(state, from, :recover, container_position(request), fn ->
      with {:ok, _} <- ContainerRequest.digest(key, request),
           {:ok, reserved, _} <- ContainerTransfers.reserve(containers, request.source),
           do: ContainerTransfers.plan(reserved, key, request, false)
    end)
  end

  defp finish_container_result(state, pending) do
    Process.cancel_timer(pending.timer)
    state = %{state | item_pending: nil}

    {reply, state} =
      case {pending.operation, pending.decision.result} do
        {{:admit, actor}, {:admitted, request, digest}} ->
          with :ok <- container_access(state, request, actor),
               {:ok, permits} <-
                 ContainerPermits.issue(
                   state.container_permits,
                   state.containers.receipts,
                   request,
                   digest,
                   System.monotonic_time(:millisecond)
                 ) do
            {{:ok, request}, %{state | container_permits: permits}}
          else
            error -> {error, state}
          end

        {_, result} ->
          {{:ok, result},
           %{
             state
             | container_permits: Map.get(pending.decision, :permits, state.container_permits)
           }}
      end

    state = notify_container_changed(state, pending.position)
    GenServer.reply(pending.from, reply)
    resume_item_handoff(state)
  end

  defp start_container_work(state, from, operation, position, work) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result = work.()
           send(owner, {:resource, epoch, {:container_recovery_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        pending = %{
          kind: :container,
          operation: operation,
          position: position,
          phase: :planning,
          token: token,
          from: from,
          worker: worker,
          monitor: Process.monitor(worker),
          timer: send_after(state, {:item_commit_deadline, token}, 5000)
        }

        {:noreply, %{state | item_pending: pending}}

      {:error, :max_children} ->
        {:reply, {:error, :item_workers_busy}, state}

      {:error, reason} ->
        {:reply, {:error, {:item_worker_failed, reason}}, state}
    end
  end

  defp cross_merge_ready(state, epoch) do
    cond do
      state.items.epoch != epoch -> {:error, :stale_region}
      not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
      state.item_pending != nil -> {:error, :item_storage_busy}
      true -> :ok
    end
  end

  defp plan_item_change(kind, request, from, state) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    items = state.items
    receipts = state.item_receipts
    key = state.key

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result = item_plan(kind, items, receipts, key, request)
           send(owner, {:resource, epoch, {:item_transfer_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        pending = %{
          kind: kind,
          phase: :planning,
          token: token,
          from: from,
          worker: worker,
          monitor: Process.monitor(worker),
          timer: send_after(state, {:item_commit_deadline, token}, 5000),
          acceptance_deadline:
            case kind do
              :item_handoff_out -> elem(request, 2)
              :pickup_admission -> elem(request, 2)
              :cross_merge_admission -> elem(request, 1)
              :item_merge -> elem(request, 1)
              :item_merge_auto -> elem(request, 1)
              _ -> nil
            end
        }

        {:noreply, %{state | item_pending: pending}}

      {:error, :max_children} ->
        {:reply, {:error, :item_workers_busy}, state}

      {:error, reason} ->
        {:reply, {:error, {:item_worker_failed, reason}}, state}
    end
  end

  defp item_plan(:item_transfer, items, receipts, key, transfer) do
    case ItemTransfers.plan(items, receipts, key, transfer) do
      {:ok, next, receipts, :applied} -> {:write, next, receipts, {:ok, :applied}}
      {:ok, _, _, :already_applied} -> {:reply, {:ok, :already_applied}}
      error -> error
    end
  end

  defp item_plan(:pickup_admission, items, receipts, _key, {actor, item_uuid, deadline}) do
    reply = {:pickup_grant, actor, item_uuid, deadline}

    case ItemReceipts.reserve(receipts, actor.uuid) do
      {:ok, _, :existing} -> {:reply, reply}
      {:ok, reserved, :reserved} -> {:write, items, reserved, reply}
      error -> error
    end
  end

  defp item_plan(:item_pickup, items, receipts, key, {request, eligible, effect}) do
    case PickupTransfers.plan(items, receipts, key, request, eligible) do
      {:ok, %{result: result}} when result in [:already_applied, :already_rejected] ->
        {:reply, {:ok, result}}

      {:ok, plan} ->
        {:write, plan.items, plan.receipts, {:pickup_result, plan.result, effect}}

      error ->
        error
    end
  end

  defp item_plan(:item_handoff_in, items, receipts, key, transfer) do
    case ItemHandoffs.accept(items, key, transfer) do
      {:ok, next, :applied} -> {:write, next, receipts, {:ok, :applied}}
      {:ok, _, :already_applied} -> {:reply, {:ok, :already_applied}}
      error -> error
    end
  end

  defp item_plan(:item_handoff_out, items, receipts, key, {destination, steps, _}) do
    with {:ok, next, request} <- ItemHandoffs.depart(items, key, items.epoch, destination, steps),
         do: {:write, next, receipts, {:ok, request.sequence}}
  end

  defp item_plan(:item_handoff_clear, items, receipts, key, {sequence, digest}) do
    result =
      case digest do
        {:item_merge, proof} ->
          case ItemMergeEscrow.finish(items, key, sequence, proof) do
            {:ok, next, _} -> {:ok, next}
            error -> error
          end

        _ ->
          ItemHandoffs.finish(items, key, sequence, digest)
      end

    with {:ok, next} <- result, do: {:write, next, receipts, :ok}
  end

  defp item_plan(:cross_merge_admission, items, receipts, key, {proposal, deadline}) do
    with {:ok, request} <- ItemMergePermits.prepare(items, key, proposal),
         {:ok, incoming, status} <-
           OwnerItemReceipts.reserve(items.ledger.incoming, request.source, key) do
      reply = {:item_merge_grant, request, deadline}

      if status == :existing,
        do: {:reply, reply},
        else: {:write, %{items | ledger: %{items.ledger | incoming: incoming}}, receipts, reply}
    end
  end

  defp item_plan(:cross_merge_out, items, receipts, key, request) do
    with {:ok, next} <- ItemMergeEscrow.prepare(items, key, items.epoch, request),
         do: {:write, next, receipts, {:ok, :prepared}}
  end

  defp item_plan(:cross_merge_in, items, receipts, key, {request, permitted}) do
    case ItemMergeInbox.apply(items, key, request, permitted) do
      {:ok, _, result} when result in [:already_applied, :already_rejected] ->
        {:reply, {:ok, result}}

      {:ok, next, result} ->
        {:write, next, receipts, {:ok, result}}

      error ->
        error
    end
  end

  defp item_plan(:cross_merge_counters, items, _, key, {request, permitted}) do
    with {:ok, next} <- ItemMergeInbox.counter_plan(items, key, request, permitted),
         do: {:reply, {:item_merge_counters, next}}
  end

  defp item_plan(:item_merge, items, receipts, _key, {pairs, _deadline}) do
    merge_plan(items, receipts, pairs)
  end

  defp item_plan(:item_merge_auto, items, receipts, _key, _) do
    case ItemMerges.candidates(items) do
      [] -> {:reply, {:ok, []}}
      pairs -> merge_plan(items, receipts, pairs)
    end
  end

  defp merge_plan(items, receipts, pairs) do
    case ItemMerges.plan(items, items.epoch, pairs) do
      {:ok, ^items, changes} -> {:reply, {:ok, changes}}
      {:ok, next, changes} -> {:write, next, receipts, {:ok, changes}}
      error -> error
    end
  end

  defp block_transfer_writing?(state),
    do:
      match?(%{kind: kind} when kind in [:container, :container_blocks], state.item_pending) or
        match?(
          %{kind: kind, phase: :writing} when kind in [:mining, :placement, :cooking_batch],
          state.item_pending
        )

  defp permit_matches?(state, kind, %{permit: token, expected: expected}) do
    {module, permits} = permit_store(state, kind)
    module.lookup(permits, token, System.monotonic_time(:millisecond)) == {:ok, expected}
  end

  defp permit_matches?(_, _, _), do: false
  defp permit_store(state, :mining), do: {MiningPermits, state.mining_permits}
  defp permit_store(state, :placement), do: {PlacementPermits, state.placement_permits}
  defp transfer_module(:mining), do: MiningTransfers
  defp transfer_module(:placement), do: PlacementTransfers

  defp plan_block_transfer(kind, transfer, from, state) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    items = state.items
    receipts = state.item_receipts
    containers = state.containers
    key = state.key
    eligible = permit_matches?(state, kind, transfer)
    module = transfer_module(kind)

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result =
             with {:ok, plan} <- module.plan(items, receipts, key, transfer, eligible) do
               plan = Map.put(plan, :kind, kind)

               if plan.result == :applied do
                 changes =
                   if kind == :placement do
                     plan.edits
                   else
                     Map.new(plan.expected, fn {pos, block} ->
                       {pos, Valimc.Physics.FluidBlocks.after_removal(block)}
                     end)
                   end

                 with {:ok, batch} <- BlockBatch.prepare(changes) do
                   plan = Map.put(plan, :batch, batch)

                   case block_container_metadata(plan, containers, key) do
                     {:ok, plan} -> {:ok, plan}
                     {:error, _} -> {:ok, module.reject(plan, items, receipts)}
                   end
                 end
               else
                 {:ok, plan}
               end
             end

           send(owner, {:resource, epoch, {:block_transfer_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        pending = %{
          kind: kind,
          phase: :planning,
          token: token,
          from: from,
          worker: worker,
          monitor: Process.monitor(worker),
          timer: send_after(state, {:item_commit_deadline, token}, 5000)
        }

        {:noreply, %{state | item_pending: pending}}

      {:error, :max_children} ->
        {:reply, {:error, :item_workers_busy}, state}

      {:error, reason} ->
        {:reply, {:error, {:item_worker_failed, reason}}, state}
    end
  end

  defp container_metadata_affected?(containers, expected, edits) do
    Enum.any?(edits, fn {position, block} ->
      Map.has_key?(containers.entries, position) or Valimc.ChestAccess.single?(block) or
        Valimc.ChestAccess.single?(expected[position]) or
        Valimc.Physics.CookingBlocks.kind(block) != nil or
        Valimc.Physics.CookingBlocks.kind(expected[position]) != nil
    end)
  end

  defp start_container_blocks(state, from, batch, expected, reply \\ :revision) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    containers = state.containers
    items = state.items
    key = state.key

    case Task.Supervisor.start_child(Valimc.ItemWorkers, fn ->
           result =
             with {:ok, change} <- ContainerLifecycle.plan(containers, key, expected, batch.edits),
                  {:ok, next} <- ContainerSpills.add(items, key, change.removed),
                  do: {:ok, Map.put(change, :items, next)}

           send(owner, {:resource, epoch, {:container_block_plan, self(), token, result}})
         end) do
      {:ok, worker} ->
        pending = %{
          kind: :container_blocks,
          reply: reply,
          phase: :planning,
          token: token,
          from: from,
          worker: worker,
          monitor: Process.monitor(worker),
          timer: send_after(state, {:item_commit_deadline, token}, 5000),
          batch: batch,
          items: state.items,
          receipts: state.item_receipts
        }

        {:noreply, %{state | item_pending: pending}}

      {:error, :max_children} ->
        {:reply, {:error, :item_workers_busy}, state}

      {:error, reason} ->
        {:reply, {:error, {:item_worker_failed, reason}}, state}
    end
  end

  defp block_container_metadata(plan, containers, key) do
    expected = Map.take(plan.expected, Map.keys(plan.batch.edits))

    affected = container_metadata_affected?(containers, expected, plan.batch.edits)

    if affected do
      with {:ok, change} <- ContainerLifecycle.plan(containers, key, expected, plan.batch.edits),
           {:ok, items} <- ContainerSpills.add(plan.items, key, change.removed) do
        {:ok,
         if(change.containers == containers,
           do: plan,
           else:
             Map.merge(plan, %{
               containers: change.containers,
               items: items,
               removed: change.removed
             })
         )}
      else
        error -> error
      end
    else
      {:ok, plan}
    end
  end

  defp block_proposal(state, batch, removed \\ []) do
    if protected_container_change?(state, batch.edits, removed),
      do: {:error, :occupied_container},
      else: build_block_proposal(state, batch)
  end

  defp build_block_proposal(state, batch) do
    edits =
      Enum.reduce(batch.edits, state.edits, fn {pos, block}, acc -> put_edit(acc, pos, block) end)

    cond do
      map_size(edits) > 131_072 ->
        {:error, :region_edit_limit}

      true ->
        by_chunk =
          Enum.reduce(batch.edits, state.by_chunk, fn {{x, _, z} = pos, block}, acc ->
            key = Valimc.World.chunk_key(x, z)
            Map.put(acc, key, put_edit(Map.get(acc, key, %{}), pos, block))
          end)

        versions =
          Enum.reduce(batch.chunks, state.versions, &Map.update(&2, &1, 1, fn n -> n + 1 end))

        {:ok,
         %{
           edits: edits,
           by_chunk: by_chunk,
           column_index: ColumnIndex.update(state.column_index, edits, batch.edits),
           versions: versions,
           revision: state.revision + 1
         }}
    end
  end

  # Raw edits cannot orphan contents. Only a fully admitted spill proposal may
  # retire the exact owned entry in its joint block/item/container WAL.
  defp protected_container_change?(state, changes, removed \\ []) do
    retired = Map.new(removed, fn %{position: position, entry: entry} -> {position, entry} end)

    Enum.any?(changes, fn {position, block} ->
      case state.containers.entries[position] do
        %{cooking: _} = entry ->
          original = Chunk.block_at(state.edits, position)

          block != original and
            not (retired[position] == entry and Valimc.World.CookingEntry.empty?(entry) and
                   Valimc.Physics.CookingBlocks.kind(original) == entry.kind and
                   Valimc.Physics.CookingBlocks.kind(block) != entry.kind)

        %{slots: slots} = entry ->
          block != Chunk.block_at(state.edits, position) and
            Enum.any?(Tuple.to_list(slots), &(&1 != nil)) and
            not (retired[position] == entry and
                   Valimc.ChestAccess.single?(Chunk.block_at(state.edits, position)) and
                   not Valimc.ChestAccess.single?(block))

        nil ->
          false
      end
    end)
  end

  defp publish_blocks(state, batch, proposal, dirty, cooking \\ false) do
    state = if cooking, do: state, else: retire_container_changes(state, batch.edits)
    :ets.insert(state.item_publication, {:block_fence, state.items.epoch, proposal.revision})
    Valimc.World.publish(state.key, {:block_batch, batch.frames})
    Valimc.Metrics.add(:block_edits, map_size(batch.edits))

    state
    |> struct!(proposal)
    |> Map.merge(%{
      cache: Map.drop(state.cache, batch.chunks),
      dirty: dirty,
      mining_permits: MiningPermits.invalidate(state.mining_permits, batch.edits),
      container_permits:
        if(cooking,
          do: state.container_permits,
          else: ContainerPermits.invalidate(state.container_permits, batch.edits)
        ),
      placement_permits: PlacementPermits.invalidate(state.placement_permits, batch.edits)
    })
  end

  defp isolated_chest_changes?(state, batch) do
    Enum.all?(batch.edits, fn {position, block} ->
      if Valimc.ChestAccess.single?(block) and
           not Valimc.ChestAccess.single?(Chunk.block_at(state.edits, position)) do
        Enum.all?(Valimc.Physics.ChestPlacement.neighbors(position), fn {x, _, z} = neighbor ->
          Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key and
            not Valimc.ChestAccess.ordinary?(
              Map.get(batch.edits, neighbor, Chunk.block_at(state.edits, neighbor))
            )
        end)
      else
        true
      end
    end)
  end

  defp commit_block_transfer(plan, pending, state) do
    cond do
      plan.result in [:already_applied, :already_rejected] ->
        GenServer.reply(pending.from, {:ok, plan.result})
        {:noreply, %{state | item_pending: nil}}

      plan.result == :rejected ->
        commit_rejected_block_transfer(plan, pending.from, state)

      not permit_matches?(state, plan.kind, plan) or
          not isolated_chest_changes?(state, plan.batch) ->
        commit_rejected_block_transfer(
          transfer_module(plan.kind).reject(plan, state.items, state.item_receipts),
          pending.from,
          state
        )

      true ->
        case block_proposal(state, plan.batch, Map.get(plan, :removed, [])) do
          {:ok, proposal} ->
            token = make_ref()

            snapshot = %{
              edits: proposal.edits,
              changes: plan.batch.edits,
              items: plan.items,
              receipts: plan.receipts
            }

            snapshot =
              if plan[:containers],
                do: Map.put(snapshot, :containers, plan.containers),
                else: snapshot

            Store.commit_mining(
              state.store,
              state.store_lease,
              snapshot,
              {self(), state.items.epoch},
              token
            )

            writing = %{
              kind: plan.kind,
              phase: :writing,
              token: token,
              timer: send_after(state, {:item_commit_deadline, token}, 5000),
              from: pending.from,
              batch: plan.batch,
              proposal: proposal,
              items: plan.items,
              receipts: plan.receipts
            }

            writing =
              if plan[:containers],
                do: Map.put(writing, :containers, plan.containers),
                else: writing

            {:noreply, %{state | item_pending: writing}}

          {:error, _} ->
            commit_rejected_block_transfer(
              transfer_module(plan.kind).reject(plan, state.items, state.item_receipts),
              pending.from,
              state
            )
        end
    end
  end

  defp commit_rejected_block_transfer(plan, from, state) do
    {module, permits} = permit_store(state, plan.kind)
    field = if plan.kind == :mining, do: :mining_permits, else: :placement_permits
    state = Map.put(state, field, module.remove(permits, plan.permit))

    {:noreply, next} =
      commit_items(
        state.items,
        {:ok, :rejected},
        from,
        state,
        plan.receipts
      )

    {:noreply, %{next | item_pending: Map.put(next.item_pending, :kind, plan.kind)}}
  end

  defp put_edit(edits, {_, y, _} = pos, block) do
    if block == Chunk.base(y), do: Map.delete(edits, pos), else: Map.put(edits, pos, block)
  end

  defp start_job(state, key) do
    job = state.jobs[key]

    if job.pid do
      state
    else
      owner = self()
      epoch = state.items.epoch
      token = make_ref()
      edits = Map.get(state.by_chunk, key, %{})
      version = Map.get(state.versions, key, 0)
      threshold = Valimc.config(:compression_threshold)

      case Task.Supervisor.start_child(Valimc.ChunkWorkers, fn ->
             started = System.monotonic_time(:microsecond)
             frame = Chunk.encode(key, edits) |> Packets.frame(threshold)
             Valimc.Metrics.add(:chunks_encoded)

             Valimc.Metrics.add(
               :chunk_encode_microseconds,
               System.monotonic_time(:microsecond) - started
             )

             send(owner, {:resource, epoch, {:encoded, key, token, version, frame}})
           end) do
        {:ok, pid} ->
          job = %{job | pid: pid, monitor: Process.monitor(pid), token: token}
          %{state | jobs: Map.put(state.jobs, key, job)}

        {:error, :max_children} ->
          send_after(state, {:retry_encode, key}, 10)
          state

        {:error, reason} ->
          for from <- job.waiters, do: GenServer.reply(from, {:error, reason})
          %{state | jobs: Map.delete(state.jobs, key)}
      end
    end
  end

  def handle_info(
        {:container_recovery_plan, worker, token, result},
        %{
          item_pending:
            %{kind: :container, phase: :planning, worker: worker, token: token} = pending
        } = state
      ) do
    Process.demonitor(pending.monitor, [:flush])

    case result do
      {:ok, %{containers: containers} = decision} ->
        pending = Map.put(pending, :decision, decision)

        if containers == state.containers do
          {:noreply, finish_container_result(state, pending)}
        else
          Store.commit_containers(
            state.store,
            state.store_lease,
            containers,
            {self(), state.items.epoch},
            token
          )

          writing = pending |> Map.drop([:worker, :monitor]) |> Map.put(:phase, :writing)
          {:noreply, %{state | item_pending: writing}}
        end

      {:error, _} = error ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, error)
        {:noreply, item_plan_failed(state, pending)}
    end
  end

  def handle_info({:container_recovery_plan, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:containers_saved, writer, token, :ok},
        %{
          store: writer,
          item_pending: %{kind: :container, phase: :writing, token: token} = pending
        } = state
      ) do
    {:noreply,
     finish_container_result(%{state | containers: pending.decision.containers}, pending)}
  end

  def handle_info(
        {:containers_saved, writer, token, {:error, reason}},
        %{
          store: writer,
          item_pending: %{kind: :container, phase: :writing, token: token} = pending
        } = state
      ) do
    Process.cancel_timer(pending.timer)
    GenServer.reply(pending.from, {:error, :container_commit_uncertain})
    {:stop, {:container_storage_failed, reason}, %{state | item_pending: nil}}
  end

  def handle_info(
        {:containers_saved, writer, token, result},
        %{store: writer, item_pending: %{kind: :cooking_checkpoint, token: token} = pending} =
          state
      ) do
    Process.cancel_timer(pending.timer)

    case result do
      :ok -> {:noreply, %{state | item_pending: nil, cooking: %{state.cooking | dirty: false}}}
      {:error, reason} -> {:stop, {:cooking_checkpoint_failed, reason}, state}
    end
  end

  def handle_info(
        {:containers_saved, writer, token, result},
        %{store: writer, item_pending: %{kind: :cooking_orbs, token: token}} = state
      ),
      do: CookingOrbRuntime.saved(state, result)

  def handle_info({:containers_saved, _, _, _}, state), do: {:noreply, state}

  def handle_info({:cooking_orb_plan, worker, token, result}, state),
    do: CookingOrbRuntime.result(state, worker, token, result)

  def handle_info({:cooking_orb_deadline, token}, state),
    do: CookingOrbRuntime.expired(state, token)

  def handle_info({:cooking_orb_delivered, worker, token, result}, state),
    do: CookingOrbDelivery.returned(state, worker, token, result)

  def handle_info({:cooking_orb_delivery_deadline, token}, state),
    do: CookingOrbDelivery.expired(state, token)

  def handle_info(
        {:cooking_plan, worker, token, result},
        %{cooking: %{job: %{worker: worker, token: token} = job}} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    state = %{state | cooking: %{state.cooking | job: nil}}

    case result do
      {:ok, plan} ->
        {:noreply, accept_cooking_plan(state, job, plan)}

      {:error, _} ->
        Valimc.Metrics.add(:cooking_plan_failures)

        {:noreply,
         %{
           state
           | cooking: %{
               state.cooking
               | seen: nil,
                 retry_at: System.monotonic_time(:millisecond) + 1000
             }
         }}
    end
  end

  def handle_info({:cooking_plan, _, _, _}, state), do: {:noreply, state}

  def handle_info({:cooking_deadline, token}, %{cooking: %{job: %{token: token} = job}} = state) do
    Process.demonitor(job.monitor, [:flush])
    Process.exit(job.worker, :kill)
    Valimc.Metrics.add(:cooking_timeouts)

    {:noreply,
     %{
       state
       | cooking: %{
           state.cooking
           | job: nil,
             seen: nil,
             retry_at: System.monotonic_time(:millisecond) + 100
         }
     }}
  end

  def handle_info({:cooking_deadline, _}, state), do: {:noreply, state}

  def handle_info(
        {:item_transfer_plan, worker, token, result},
        %{
          item_pending: %{kind: kind, phase: :planning, worker: worker, token: token} = pending
        } = state
      )
      when kind in [
             :item_transfer,
             :item_handoff_in,
             :item_handoff_out,
             :item_handoff_clear,
             :item_merge,
             :item_merge_auto,
             :pickup_admission,
             :item_pickup,
             :cross_merge_admission,
             :cross_merge_out,
             :cross_merge_in,
             :cross_merge_counters
           ] do
    Process.demonitor(pending.monitor, [:flush])

    result =
      if pending.acceptance_deadline != nil and
           System.monotonic_time(:millisecond) >= pending.acceptance_deadline,
         do: {:error, :expired_item_step},
         else: result

    case result do
      {:write, items, receipts, reply} ->
        Store.commit_items(
          state.store,
          state.store_lease,
          items,
          receipts,
          {self(), state.items.epoch},
          token
        )

        writing =
          pending
          |> Map.drop([:worker, :monitor])
          |> Map.merge(%{
            phase: :writing,
            items: items,
            receipts: receipts,
            reply: reply
          })

        {:noreply, %{state | item_pending: writing}}

      {:reply, reply} ->
        Process.cancel_timer(pending.timer)
        next = finish_item_reply(%{state | item_pending: nil}, pending.from, reply)
        {:noreply, resume_item_handoff(next)}

      {:error, _} = error ->
        Process.cancel_timer(pending.timer)
        reply_item(pending.from, error)
        {:noreply, item_plan_failed(state, pending)}
    end
  end

  def handle_info({:item_transfer_plan, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:item_cross_query, worker, token, result},
        %{item_cross_job: %{worker: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    retry = job.retry or result.retry

    complete =
      result.cursor == nil and not retry and not result.progress and
        job.scan_stamp == job.stamp

    next =
      System.monotonic_time(:millisecond) +
        if(result.progress or result.cursor != nil, do: 0, else: 200)

    {:noreply,
     %{
       state
       | item_cross_job: nil,
         item_cross_next: next,
         item_cross_stamp: if(complete, do: job.stamp),
         item_cross_scan_stamp: if(result.cursor != nil, do: job.scan_stamp),
         item_cross_cursor: result.cursor,
         item_cross_retry: result.cursor != nil and retry
     }}
  end

  def handle_info({:item_cross_query, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:item_cross_deadline, token},
        %{item_cross_job: %{token: token} = job} = state
      ) do
    Process.demonitor(job.monitor, [:flush])
    Process.exit(job.worker, :kill)
    Valimc.Metrics.add(:item_cross_timeouts)
    {:noreply, %{state | item_cross_job: nil}}
  end

  def handle_info({:item_cross_deadline, _}, state), do: {:noreply, state}

  def handle_info({:release_pickup, token, source}, state),
    do:
      {:noreply,
       %{state | pickup_permits: PickupPermits.release(state.pickup_permits, token, source)}}

  def handle_info(
        {:item_simulation, worker, token, result},
        %{item_simulation: %{worker: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    state = %{state | item_simulation: nil}

    case result do
      {:ok, %{steps: steps, refused: refused, fences: fences}} ->
        Valimc.Metrics.add(:item_simulation_refusals, length(refused))

        if state.item_pending == nil and System.monotonic_time(:millisecond) < job.deadline and
             Valimc.World.item_frame_current?(fences),
           do: commit_simulated_items(state, steps, fences),
           else: {:noreply, state}

      {:error, _} ->
        Valimc.Metrics.add(:item_simulation_failures)
        {:noreply, state}
    end
  end

  def handle_info({:item_simulation, _, _, _}, state), do: {:noreply, state}

  def handle_info({:release_item_merge, token, source}, state),
    do:
      {:noreply,
       %{
         state
         | item_merge_permits: ItemMergePermits.release(state.item_merge_permits, token, source)
       }}

  def handle_info(
        {:item_simulation_deadline, token},
        %{item_simulation: %{token: token} = job} = state
      ) do
    Process.demonitor(job.monitor, [:flush])
    Process.exit(job.worker, :kill)
    Valimc.Metrics.add(:item_simulation_timeouts)
    {:noreply, %{state | item_simulation: nil}}
  end

  def handle_info({:item_simulation_deadline, _}, state), do: {:noreply, state}

  def handle_info(
        {:item_handoff_wake, token},
        %{item_handoff: %{phase: :retry, token: token}} = state
      ) do
    token = make_ref()

    case ItemHandoffDelivery.start(
           self(),
           state.items.epoch,
           token,
           state.key,
           state.items.ledger
         ) do
      {:ok, worker, monitor} ->
        job = %{
          phase: :delivering,
          token: token,
          worker: worker,
          monitor: monitor,
          timer: send_after(state, {:item_handoff_deadline, token}, 8000)
        }

        {:noreply, %{state | item_handoff: job}}

      {:error, _} ->
        {:noreply, schedule_handoff_retry(state, 250)}
    end
  end

  def handle_info(
        {:item_handoff_wake, token},
        %{item_handoff: %{phase: :ready_clear, token: token} = ack} = state
      ) do
    if state.item_pending != nil do
      {:noreply, schedule_handoff_clear(state, ack.sequence, ack.digest, 100)}
    else
      case plan_item_change(:item_handoff_clear, {ack.sequence, ack.digest}, nil, state) do
        {:noreply, next} ->
          {:noreply, %{next | item_handoff: %{phase: :clearing}}}

        {:reply, _, next} ->
          {:noreply, schedule_handoff_clear(next, ack.sequence, ack.digest, 100)}
      end
    end
  end

  def handle_info({:item_handoff_wake, _}, state), do: {:noreply, state}

  def handle_info(
        {:item_handoff_delivered, worker, token, result},
        %{item_handoff: %{phase: :delivering, worker: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])

    case result do
      {:ok, sequence, digest} ->
        {:noreply, schedule_handoff_clear(state, sequence, digest, 0)}

      {:error, _} ->
        Valimc.Metrics.add(:item_handoff_retries)
        {:noreply, schedule_handoff_retry(state, 250)}
    end
  end

  def handle_info({:item_handoff_delivered, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:item_handoff_deadline, token},
        %{item_handoff: %{phase: :delivering, token: token} = job} = state
      ) do
    Process.demonitor(job.monitor, [:flush])
    Process.exit(job.worker, :kill)
    Valimc.Metrics.add(:item_handoff_retries)
    {:noreply, schedule_handoff_retry(state, 250)}
  end

  def handle_info({:item_handoff_deadline, _}, state), do: {:noreply, state}

  def handle_info(
        {:container_block_plan, worker, token, result},
        %{
          item_pending:
            %{kind: :container_blocks, phase: :planning, token: token, worker: worker} = pending
        } = state
      ) do
    Process.demonitor(pending.monitor, [:flush])

    case result do
      {:ok, %{containers: containers, removed: removed, items: items}} ->
        case block_proposal(state, pending.batch, removed) do
          {:ok, proposal} ->
            snapshot = %{
              edits: proposal.edits,
              changes: pending.batch.edits,
              items: items,
              receipts: pending.receipts,
              containers: containers
            }

            Store.commit_mining(
              state.store,
              state.store_lease,
              snapshot,
              {self(), state.items.epoch},
              token
            )

            writing =
              pending
              |> Map.drop([:worker, :monitor])
              |> Map.merge(%{
                phase: :writing,
                proposal: proposal,
                containers: containers,
                items: items
              })

            {:noreply, %{state | item_pending: writing}}

          {:error, _} = error ->
            Process.cancel_timer(pending.timer)
            GenServer.reply(pending.from, error)
            {:noreply, item_plan_failed(state, pending)}
        end

      {:error, _} = error ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, error)
        {:noreply, item_plan_failed(state, pending)}
    end
  end

  def handle_info({:container_block_plan, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:block_transfer_plan, worker, token, result},
        %{
          item_pending: %{kind: kind, phase: :planning, worker: worker, token: token} = pending
        } = state
      )
      when kind in [:mining, :placement] do
    Process.demonitor(pending.monitor, [:flush])
    Process.cancel_timer(pending.timer)

    case result do
      {:ok, %{kind: ^kind} = plan} ->
        commit_block_transfer(plan, pending, state)

      {:error, _} = error ->
        GenServer.reply(pending.from, error)
        {:noreply, %{state | item_pending: nil}}
    end
  end

  def handle_info({:block_transfer_plan, _, _, _}, state), do: {:noreply, state}

  def handle_info(
        {:mining_saved, writer, token, :ok},
        %{
          store: writer,
          item_pending: %{kind: kind, phase: :writing, token: token, batch: batch} = pending
        } = state
      )
      when kind in [:mining, :placement, :container_blocks] do
    Process.cancel_timer(pending.timer)
    next = publish_blocks(state, batch, pending.proposal, false)
    :ets.insert(state.item_publication, {:items, pending.items.views})

    reply =
      cond do
        kind != :container_blocks -> {:ok, :applied}
        pending.reply == :ok -> :ok
        true -> {:ok, next.revision}
      end

    GenServer.reply(pending.from, reply)

    {:noreply,
     %{
       next
       | items: pending.items,
         item_receipts: pending.receipts,
         containers: Map.get(pending, :containers, state.containers),
         item_pending: nil,
         item_saved_generation: state.item_motion_generation
     }}
  end

  def handle_info(
        {:mining_saved, writer, token, {:error, reason}},
        %{
          store: writer,
          item_pending: %{kind: kind, phase: :writing, token: token, batch: _} = pending
        } = state
      )
      when kind in [:mining, :placement, :container_blocks] do
    Process.cancel_timer(pending.timer)
    GenServer.reply(pending.from, {:error, :mining_commit_uncertain})
    {:stop, {:mining_storage_failed, reason}, %{state | item_pending: nil}}
  end

  def handle_info(
        {:mining_saved, writer, token, result},
        %{store: writer, item_pending: %{kind: :cooking_batch, token: token} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)

    case result do
      :ok ->
        plan = Map.put(pending.plan, :proposal, pending.proposal)
        {:noreply, finish_cooking(%{state | item_pending: nil}, plan, true)}

      {:error, reason} ->
        {:stop, {:cooking_storage_failed, reason}, state}
    end
  end

  def handle_info({:mining_saved, _, _, _}, state), do: {:noreply, state}

  def handle_info({:item_checkpoint, token}, %{item_checkpoint_timer: %{token: token}} = state) do
    state = %{state | item_checkpoint_timer: nil}

    cond do
      state.item_saved_generation == state.item_motion_generation ->
        {:noreply, state}

      state.item_pending != nil ->
        {:noreply, schedule_item_checkpoint(state)}

      state.item_checkpoint != nil ->
        {:noreply, state}

      true ->
        token = make_ref()

        Store.commit_items(
          state.store,
          state.store_lease,
          state.items,
          state.item_receipts,
          {self(), state.items.epoch},
          token
        )

        checkpoint = %{
          token: token,
          generation: state.item_motion_generation,
          timer: send_after(state, {:item_checkpoint_deadline, token}, 5000)
        }

        {:noreply, %{state | item_checkpoint: checkpoint}}
    end
  end

  def handle_info({:item_checkpoint, _}, state), do: {:noreply, state}

  def handle_info(
        {:items_saved, writer, token, :ok},
        %{store: writer, item_checkpoint: %{token: token} = checkpoint} = state
      ) do
    Process.cancel_timer(checkpoint.timer)
    saved = max(state.item_saved_generation, checkpoint.generation)

    {:noreply,
     schedule_item_checkpoint(%{state | item_checkpoint: nil, item_saved_generation: saved})}
  end

  def handle_info(
        {:items_saved, writer, token, {:error, reason}},
        %{store: writer, item_checkpoint: %{token: token} = checkpoint} = state
      ) do
    Process.cancel_timer(checkpoint.timer)
    {:stop, {:item_checkpoint_failed, reason}, %{state | item_checkpoint: nil}}
  end

  def handle_info(
        {:item_checkpoint_deadline, token},
        %{item_checkpoint: %{token: token}} = state
      ),
      do: {:stop, :item_checkpoint_timeout, state}

  def handle_info({:item_checkpoint_deadline, _}, state), do: {:noreply, state}

  def handle_info(
        {:items_saved, writer, token, :ok},
        %{store: writer, item_pending: %{phase: :writing, token: token} = pending} = state
      )
      when not is_map_key(pending, :batch) do
    Process.cancel_timer(pending.timer)
    :ets.insert(state.item_publication, {:items, pending.items.views})

    {:noreply,
     %{
       state
       | items: pending.items,
         item_receipts: pending.receipts,
         item_pending: nil,
         item_saved_generation: state.item_motion_generation
     }
     |> finish_item_reply(pending.from, pending.reply)
     |> resume_item_handoff()}
  end

  def handle_info(
        {:items_saved, writer, token, {:error, reason}},
        %{store: writer, item_pending: %{phase: :writing, token: token} = pending} = state
      )
      when not is_map_key(pending, :batch) do
    Process.cancel_timer(pending.timer)
    reply_item(pending.from, {:error, :item_commit_uncertain})
    require Logger
    Logger.error("Region item commit failed: #{inspect(reason)}")
    {:stop, {:item_storage_failed, reason}, %{state | item_pending: nil}}
  end

  def handle_info({:items_saved, _, _, _}, state), do: {:noreply, state}

  def handle_info({:item_commit_deadline, token}, %{item_pending: %{token: token}} = state),
    do: {:stop, :item_storage_timeout, state}

  def handle_info({:item_commit_deadline, _}, state), do: {:noreply, state}

  def handle_info({:encoded, key, token, version, frame}, state) do
    case state.jobs[key] do
      %{token: ^token} = job ->
        Process.demonitor(job.monitor, [:flush])

        if version == Map.get(state.versions, key, 0) do
          for from <- job.waiters, do: GenServer.reply(from, frame)

          {:noreply,
           %{state | jobs: Map.delete(state.jobs, key), cache: Map.put(state.cache, key, frame)}}
        else
          Valimc.Metrics.add(:stale_chunk_results_discarded)
          job = %{job | pid: nil, monitor: nil, token: nil}
          {:noreply, start_job(%{state | jobs: Map.put(state.jobs, key, job)}, key)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:retry_encode, key}, state) do
    if Map.has_key?(state.jobs, key),
      do: {:noreply, start_job(state, key)},
      else: {:noreply, state}
  end

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{item_pending: %{phase: :planning, monitor: ref, worker: worker} = pending} = state
      ) do
    Process.cancel_timer(pending.timer)
    reply_item(pending.from, {:error, :item_plan_failed})
    {:noreply, item_plan_failed(state, pending)}
  end

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{item_cross_job: %{monitor: ref, worker: worker} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Valimc.Metrics.add(:item_cross_failures)
    {:noreply, %{state | item_cross_job: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{item_simulation: %{monitor: ref, worker: worker} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    {:noreply, %{state | item_simulation: nil}}
  end

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{item_handoff: %{phase: :delivering, monitor: ref, worker: worker} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Valimc.Metrics.add(:item_handoff_retries)
    {:noreply, schedule_handoff_retry(state, 250)}
  end

  def handle_info(
        {:DOWN, ref, :process, writer, reason},
        %{store: writer, store_monitor: ref} = state
      ),
      do: {:stop, {:store_failed, reason}, state}

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{cooking: %{job: %{worker: worker, monitor: ref} = job}} = state
      ) do
    Process.cancel_timer(job.timer)
    Valimc.Metrics.add(:cooking_plan_failures)

    {:noreply,
     %{
       state
       | cooking: %{
           state.cooking
           | job: nil,
             seen: nil,
             retry_at: System.monotonic_time(:millisecond) + 100
         }
     }}
  end

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{cooking_orbs: %{delivery: %{worker: worker, monitor: ref}}} = state
      ),
      do: CookingOrbDelivery.down(state)

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{cooking_orbs: %{job: %{worker: worker, monitor: ref}}} = state
      ),
      do: CookingOrbRuntime.down(state)

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    state =
      apply_container_viewers(state, ContainerViewers.down(state.container_viewers, pid, ref))

    case Enum.find(state.jobs, fn {_, job} -> job.monitor == ref end) do
      {key, job} ->
        for from <- job.waiters, do: GenServer.reply(from, {:error, {:encoder_failed, reason}})
        {:noreply, %{state | jobs: Map.delete(state.jobs, key)}}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info(:save, state) do
    saving = state.dirty and not state.saving and not block_transfer_writing?(state)

    if saving,
      do:
        Store.snapshot(
          state.store,
          state.store_lease,
          state.edits,
          {self(), state.items.epoch},
          state.revision
        )

    Process.cancel_timer(state.save_timer)
    timer = send_after(state, :save, 30_000)
    {:noreply, %{state | saving: state.saving or saving, save_timer: timer}}
  end

  def handle_info({:saved, writer, revision, result}, %{store: writer} = state) do
    {:noreply, %{state | saving: false, dirty: result != :ok or revision != state.revision}}
  end

  def handle_info({:saved, _, _, _}, state), do: {:noreply, state}

  def handle_info({:table_request, epoch, connection, ref, position, grant}, state)
      when is_pid(connection) and is_reference(ref) do
    decision =
      cond do
        epoch != state.items.epoch ->
          {:error, :stale_owner}

        not valid_block_query?([position], :any) ->
          {:error, :invalid_block_query}

        Valimc.World.region_key(Valimc.World.chunk_key(elem(position, 0), elem(position, 2))) !=
            state.key ->
          {:error, :wrong_region}

        true ->
          block = Chunk.block_at(state.edits, position)
          now = System.monotonic_time(:millisecond)

          cond do
            Valimc.Physics.CookingBlocks.kind(block) != nil or
                (is_map(grant) and grant[:menu] == :cooking) ->
              Valimc.CookingOpening.authorize(
                block,
                state.containers.entries[position],
                position,
                grant,
                now
              )

            Valimc.ChestAccess.single?(block) or (is_map(grant) and grant[:menu] == :chest) ->
              {x, y, z} = position

              Valimc.ChestOpening.authorize(
                block,
                state.containers.entries[position],
                Chunk.block_at(state.edits, {x, y + 1, z}),
                position,
                grant,
                now
              )

            true ->
              Valimc.TableAccess.authorize(block, position, grant, now)
          end
      end

    {decision, state} = container_view_decision(state, connection, position, grant, decision)

    Valimc.Connection.deliver(
      connection,
      {:table_admitted, ref, {self(), state.items.epoch}, decision}
    )

    {:noreply, state}
  end

  def handle_info({:container_unsubscribe, connection, ref}, state) do
    {:noreply,
     apply_container_viewers(
       state,
       ContainerViewers.unregister(state.container_viewers, connection, ref)
     )}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp container_view_decision(state, connection, position, grant, decision) do
    generation = Map.get(state.cooking_progress, position, 0)

    decision =
      case decision do
        {:cooking, block, entry} -> {:cooking, block, Map.put(entry, :generation, generation)}
        _ -> decision
      end

    if is_map(grant) and grant[:menu] in [:chest, :cooking] and
         (decision == :valid or match?({kind, _, _} when kind in [:chest, :cooking], decision)) do
      ref = grant[:view_ref]
      view = state.container_viewers.views[connection]
      opener = grant.menu == :chest and grant.mode != :spectator

      cond do
        grant.kind == :subscribe and is_reference(ref) ->
          monitor =
            if view && view.ref == ref, do: view.monitor, else: Process.monitor(connection)

          entry = state.containers.entries[position]

          case ContainerViewers.register(
                 state.container_viewers,
                 connection,
                 ref,
                 monitor,
                 position,
                 opener,
                 entry.revision
               ) do
            {:ok, viewers, retired, lids} ->
              viewers =
                if grant.menu == :cooking,
                  do: ContainerViewers.observed_progress(viewers, connection, ref, generation),
                  else: viewers

              state = apply_container_viewers(state, {viewers, retired, lids})
              {decision, state}

            {:error, _} = error ->
              if view == nil or view.monitor != monitor, do: Process.demonitor(monitor, [:flush])
              {error, state}
          end

        view != nil and view.ref == ref and view.position == position and
            view.opener == opener ->
          viewers =
            ContainerViewers.observed(
              state.container_viewers,
              connection,
              ref,
              state.containers.entries[position].revision
            )

          viewers =
            if grant.menu == :cooking,
              do: ContainerViewers.observed_progress(viewers, connection, ref, generation),
              else: viewers

          {decision, %{state | container_viewers: viewers}}

        true ->
          {{:error, :stale_container_view}, state}
      end
    else
      {decision, state}
    end
  end

  defp notify_container_changed(state, position) do
    case state.containers.entries[position] do
      %{revision: revision} ->
        {viewers, notices} = ContainerViewers.changed(state.container_viewers, position, revision)

        for {pid, ref, revision} <- notices,
            do:
              Valimc.Connection.deliver(
                pid,
                {:container_changed, {self(), state.items.epoch}, ref, position, revision}
              )

        %{state | container_viewers: viewers}

      _ ->
        state
    end
  end

  defp retire_container_changes(state, edits) do
    positions =
      for {position, block} <- edits, Chunk.block_at(state.edits, position) != block, do: position

    {viewers, retired, lids} = ContainerViewers.invalidate(state.container_viewers, positions)

    for view <- retired,
        do:
          Valimc.Connection.deliver(
            view.pid,
            {:container_closed, {self(), state.items.epoch}, view.ref}
          )

    apply_container_viewers(state, {viewers, retired, lids}, false)
  end

  defp apply_container_viewers(state, {viewers, retired, lids}, sound? \\ true) do
    for view <- retired, do: Process.demonitor(view.monitor, [:flush])
    state = %{state | container_viewers: viewers}
    threshold = Valimc.config(:compression_threshold)

    for chunk <-
          lids |> Enum.map(fn {{x, _, z}, _} -> Valimc.World.chunk_key(x, z) end) |> Enum.uniq() do
      positions =
        for {{x, _, z} = position, {_, count}} <- viewers.positions,
            count > 0 and Valimc.World.chunk_key(x, z) == chunk,
            do: position

      positions = Enum.sort(positions)

      if positions == [] do
        :ets.delete(state.item_publication, {:container_lids, chunk})
      else
        frame =
          positions
          |> Enum.map(&Packets.frame(Packets.chest_lid(&1, true), threshold))
          |> IO.iodata_to_binary()

        :ets.insert(
          state.item_publication,
          {{:container_lids, chunk}, state.items.epoch, positions, frame}
        )
      end
    end

    for {position, open} <- lids do
      frame = Packets.frame(Packets.chest_lid(position, open), threshold)

      sound =
        if sound? do
          <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
          draw = (:rand.uniform(16_777_216) - 1) / 16_777_216
          {:ok, packet} = Valimc.Protocol.ChestSounds.packet(open, position, draw, seed)
          Packets.frame(packet, threshold)
        end

      Valimc.World.publish(
        state.key,
        {:chest_lid, {self(), state.items.epoch}, position, open, frame, sound}
      )
    end

    state
  end

  def valid_block_query?(positions, revision),
    do:
      (revision == :any or (is_integer(revision) and revision >= 0)) and
        valid_block_positions?(positions, 0)

  def valid_column_query?(columns, revision),
    do:
      (revision == :any or (is_integer(revision) and revision >= 0)) and
        valid_columns?(columns, 0)

  defp valid_columns?([], _), do: true

  defp valid_columns?([{x, z} | rest], count)
       when count < 128 and is_integer(x) and is_integer(z),
       do: abs(x) < 30_000_000 and abs(z) < 30_000_000 and valid_columns?(rest, count + 1)

  defp valid_columns?(_, _), do: false

  defp valid_block_positions?([], _), do: true

  defp valid_block_positions?([{x, y, z} | rest], count)
       when count < 128 and is_integer(x) and is_integer(y) and is_integer(z) do
    abs(x) < 30_000_000 and abs(z) < 30_000_000 and abs(y) <= 1_000_000 and
      valid_block_positions?(rest, count + 1)
  end

  defp valid_block_positions?(_, _), do: false

  defp send_after(state, message, delay),
    do: Process.send_after(self(), {:resource, state.items.epoch, message}, delay)

  defp reply_item(nil, _), do: :ok
  defp reply_item(from, reply), do: GenServer.reply(from, reply)

  defp pickup_effect(items, %{remainder: nil} = request, %{actor: %{entity_id: collector}}, true)
       when is_integer(collector) and collector in 1..2_147_483_647 do
    with {:ok, {epoch, id, _}} <- Items.find(items, request.item_uuid),
         do: {:item_pickup, epoch, id, collector, request.before.count},
         else: (_ -> nil)
  end

  defp pickup_effect(_, _, _, _), do: nil

  defp finish_item_reply(state, from, {:pickup_result, result, effect}) do
    if result == :applied and effect != nil, do: Valimc.World.publish(state.key, effect)
    reply_item(from, {:ok, result})
    state
  end

  defp finish_item_reply(state, from, {:pickup_grant, actor, item_uuid, deadline}) do
    now = System.monotonic_time(:millisecond)

    result =
      if now < deadline,
        do:
          PickupPermits.issue(
            state.pickup_permits,
            state.item_receipts,
            state.items,
            actor,
            item_uuid,
            now
          ),
        else: {:error, :expired_item_step}

    case result do
      {:ok, permits, grant} ->
        reply_item(from, {:ok, grant})
        %{state | pickup_permits: permits}

      error ->
        reply_item(from, error)
        state
    end
  end

  defp finish_item_reply(state, from, {:item_merge_grant, request, deadline}) do
    now = System.monotonic_time(:millisecond)

    result =
      if now < deadline,
        do:
          ItemMergePermits.grant(
            state.item_merge_permits,
            state.items.ledger.incoming,
            request,
            now
          ),
        else: {:error, :expired_item_step}

    case result do
      {:ok, permits, request} ->
        reply_item(from, {:ok, request})
        %{state | item_merge_permits: permits}

      error ->
        reply_item(from, error)
        state
    end
  end

  defp finish_item_reply(state, from, {:item_merge_counters, items}) do
    reply_item(from, {:ok, if(items == state.items, do: :unchanged, else: :applied)})

    if items == state.items do
      state
    else
      :ets.insert(state.item_publication, {:items, items.views})

      schedule_item_checkpoint(%{
        state
        | items: items,
          item_motion_generation: state.item_motion_generation + 1
      })
    end
  end

  defp finish_item_reply(state, from, reply) do
    reply_item(from, reply)
    state
  end

  defp commit_simulated_items(state, steps, fences) do
    steps =
      Enum.flat_map(steps, fn step ->
        case state.items.entries[step.id] do
          %{motion: counters, physical_revision: revision} = entry
          when revision == step.physical_revision ->
            [
              %{
                step
                | revision: entry.revision,
                  motion: %{step.motion | age: counters.age, pickup_delay: counters.pickup_delay}
              }
            ]

          _ ->
            []
        end
      end)

    {local, borders} =
      Enum.split_with(steps, fn %{position: {x, _, z}} ->
        Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key
      end)

    state =
      Enum.reduce(Enum.chunk_every(local, 32), state, fn batch, acc ->
        {:reply, _, next} =
          handle_call(
            {:publish_item_motion, acc.items.epoch, batch,
             System.monotonic_time(:millisecond) + 250},
            nil,
            acc
          )

        next
      end)

    resting =
      Enum.reduce(local, state.item_resting, fn step, cache ->
        if rests?(step.motion),
          do: Map.put(cache, step.id, {state.items.entries[step.id].physical_revision, fences}),
          else: Map.delete(cache, step.id)
      end)

    state = %{state | item_resting: resting}

    if borders != [] and state.items.ledger.outgoing == nil and state.item_storage_enabled do
      {destination, batch} =
        borders
        |> Enum.group_by(fn %{position: {x, _, z}} ->
          Valimc.World.region_key(Valimc.World.chunk_key(x, z))
        end)
        |> Enum.sort_by(&elem(&1, 0))
        |> hd()

      case plan_item_change(
             :item_handoff_out,
             {destination, Enum.take(batch, 32), System.monotonic_time(:millisecond) + 250},
             nil,
             state
           ) do
        {:noreply, next} -> {:noreply, next}
        {:reply, _, next} -> {:noreply, next}
      end
    else
      {:noreply, start_item_merging(state, System.monotonic_time(:millisecond))}
    end
  end

  defp rests?(%{velocity: {x, y, z}, on_ground: ground, no_gravity: floating}),
    do: (ground or floating) and y == 0.0 and x * x + z * z <= 1.0e-10

  defp resume_item_handoff(%{items: %{ledger: %{outgoing: nil}}} = state),
    do: %{state | item_handoff: nil}

  defp resume_item_handoff(%{item_handoff: nil} = state), do: schedule_handoff_retry(state, 0)
  defp resume_item_handoff(state), do: state

  defp schedule_handoff_retry(state, delay) do
    token = make_ref()
    timer = send_after(state, {:item_handoff_wake, token}, delay)
    %{state | item_handoff: %{phase: :retry, token: token, timer: timer}}
  end

  defp schedule_handoff_clear(state, sequence, digest, delay) do
    token = make_ref()
    timer = send_after(state, {:item_handoff_wake, token}, delay)

    %{
      state
      | item_handoff: %{
          phase: :ready_clear,
          sequence: sequence,
          digest: digest,
          token: token,
          timer: timer
        }
    }
  end

  defp item_plan_failed(state, pending) do
    state = %{state | item_pending: nil}

    state =
      if Map.get(pending, :kind) == :item_merge_auto,
        do: %{state | item_merge_stamp: nil},
        else: state

    state =
      if Map.get(pending, :kind) == :item_handoff_clear,
        do: %{state | item_handoff: nil},
        else: state

    resume_item_handoff(state)
  end

  def terminate(reason, state) do
    Process.cancel_timer(state.save_timer)
    CookingOrbRuntime.terminate(state.cooking_orbs)
    CookingOrbDelivery.terminate(state.cooking_orbs)

    if state.cooking.job do
      Process.cancel_timer(state.cooking.job.timer)
      Process.exit(state.cooking.job.worker, :kill)
    end

    if state.item_checkpoint_timer, do: Process.cancel_timer(state.item_checkpoint_timer.timer)
    if state.item_checkpoint, do: Process.cancel_timer(state.item_checkpoint.timer)

    if state.item_simulation do
      Process.cancel_timer(state.item_simulation.timer)
      Process.exit(state.item_simulation.worker, :kill)
    end

    if state.item_cross_job do
      Process.cancel_timer(state.item_cross_job.timer)
      Process.exit(state.item_cross_job.worker, :kill)
    end

    if state.item_handoff do
      if Map.has_key?(state.item_handoff, :timer),
        do: Process.cancel_timer(state.item_handoff.timer)

      if Map.has_key?(state.item_handoff, :worker),
        do: Process.exit(state.item_handoff.worker, :kill)
    end

    if state.item_pending do
      Process.cancel_timer(state.item_pending.timer)
      reply_item(state.item_pending.from, {:error, :item_commit_uncertain})

      if state.item_pending.phase == :planning and Process.whereis(Valimc.ItemWorkers) != nil,
        do: Task.Supervisor.terminate_child(Valimc.ItemWorkers, state.item_pending.worker)
    end

    for {_, job} <- state.jobs,
        job.pid != nil and Process.whereis(Valimc.ChunkWorkers) != nil,
        do: Task.Supervisor.terminate_child(Valimc.ChunkWorkers, job.pid)

    # All casts and flushes originate from this owner and reach its leased writer
    # in order. A queued critical proposal must never be followed by old items.
    writing_items =
      match?(%{phase: :writing}, state.item_pending) and
        not match?(
          %{kind: kind} when kind in [:container, :cooking_checkpoint, :cooking_orbs],
          state.item_pending
        )

    if reason in [:normal, :shutdown] and not writing_items,
      do: flush_item_motion(state)

    if reason in [:normal, :shutdown] and state.dirty do
      # A queued atomic write must never be followed by the old pre-commit snapshot.
      edits =
        case state.item_pending do
          %{kind: kind, phase: :writing, proposal: proposal}
          when kind in [:mining, :placement, :container_blocks] ->
            proposal.edits

          %{kind: :cooking_batch, phase: :writing, proposal: %{edits: edits}} ->
            edits

          _ ->
            state.edits
        end

      Store.flush(state.store, state.store_lease, edits)
    end

    if reason in [:normal, :shutdown] do
      # Follow queued writes with their successor, never the old pre-commit containers.
      containers =
        case state.item_pending do
          %{kind: :cooking_orbs, phase: :writing} = pending ->
            CookingOrbRuntime.shutdown_containers(state, pending)

          %{phase: :writing, plan: %{containers: containers}} ->
            containers

          %{phase: :writing, decision: %{containers: containers}} ->
            containers

          %{phase: :writing, containers: containers} ->
            containers

          _ ->
            state.containers
        end

      if containers != nil, do: flush_cooking(state, containers)
    end

    Process.demonitor(state.store_monitor, [:flush])

    if Process.alive?(state.store) do
      try do
        Store.close(state.store, state.store_lease)
      catch
        :exit, _ -> Process.exit(state.store, :kill)
      end
    end
  end
end
