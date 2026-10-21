defmodule Valimc.World.RegionData do
  @moduledoc "One storage resource's data and operations, executed by its owning process."
  alias Valimc.World.{
    BlockEntities,
    Generator,
    LootChests,
    EntityPublication,
    ScheduledTicks,
    TickBehaviours,
    BlockBatch,
    Blocks,
    BlockSnapshot,
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
    Items,
    ItemHandoffs,
    ItemHandoffDelivery,
    ItemPortals,
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
    RegionGeneration,
    RegionStorage,
    Tickets
  }

  alias Valimc.Protocol.Packets
  alias Valimc.Txn.Permits
  alias Valimc.Block.Rules

  defstruct [
    :block_entities,
    :key,
    :containers,
    :container_viewers,
    :cooking_progress,
    :cooking,
    :cooking_orbs,
    :items,
    :item_receipts,
    :item_storage_enabled,
    :item_publication,
    :item_pending,
    :item_handoff,
    :item_simulation,
    :item_simulation_enabled,
    :item_portal,
    :item_merge_stamp,
    :item_merge_next,
    :item_cross_job,
    :item_cross_next,
    :item_cross_stamp,
    :item_cross_scan_stamp,
    :item_cross_cursor,
    :item_cross_retry,
    :item_resting,
    :permits,
    :blocks,
    :cache,
    :jobs,
    :versions,
    # Chunks a client has asked for since load: only their light changes are
    # published (VMC-071); a later request carries the current light.
    :served,
    # Chunks not generated yet and their generation (VMC-075).
    :generation,
    # Chunk tickets and since when (monotonic ms) the owner has been idle (VMC-077e).
    :tickets,
    :idle_since,
    :revision,
    :section_revisions,
    :game_tick,
    :orb_age_ticks,
    :item_age_debt,
    :scheduled_ticks,
    :tick_index,
    :rule_backlog,
    :random_tick_speed,
    # Durability: keyed change records on the shared log (VMC-077f).
    :storage
  ]

  # A generated world's region loads without generating: chunks its log has no
  # column for are absent until they are wanted and generated (VMC-075,
  # `RegionGeneration`).
  def load(key) do
    {storage, loaded} =
      case RegionStorage.open(key) do
        {:ok, storage, loaded} -> {storage, loaded}
        {:error, reason} -> exit({:shutdown, {:region_storage_unavailable, reason}})
      end

    images = loaded.columns
    generation = RegionGeneration.new(key, images)

    blocks =
      case Blocks.new(key, loaded.cells, images, generation.absent) do
        {:ok, blocks} ->
          blocks

        {:error, reason} ->
          exit({:block_load_failed, reason})
      end

    block_entities =
      case BlockEntities.new(loaded.block_entities) do
        {:ok, block_entities} -> block_entities
        {:error, reason} -> exit({:block_entity_load_failed, reason})
      end

    items =
      case Items.restore(key, loaded.items, loaded.ledger) do
        {:ok, items} -> items
        {:error, reason} -> exit({:item_load_failed, reason})
      end

    # Scheduled ticks are due at the region's game tick, which continues.
    scheduled =
      ScheduledTicks.load(
        for(
          {pos, block, due, priority} <- loaded.ticks,
          do: {pos, block, due - loaded.game_tick, priority}
        ),
        loaded.game_tick
      )

    tick_index = TickBehaviours.index(TickBehaviours.modules(key))

    # The native sampler returns only states some behaviour handles randomly.
    :ok =
      Blocks.random_ticking(
        blocks,
        for({state, module} <- tick_index, function_exported?(module, :random_tick, 4), do: state)
      )

    publication = :ets.new(:region_items, [:set, :protected, read_concurrency: true])
    # Every generated chunk has a row, with its heightmaps and biomes (VMC-077e).
    present =
      for chunk <- Valimc.Worldgen.Proto.chunks_of(key),
          not RegionGeneration.absent?(generation, chunk),
          do: chunk

    :ok = BlockSnapshot.publish_chunks(publication, blocks, present, 0)
    :ok = BlockSnapshot.publish_absent(publication, MapSet.to_list(generation.absent))
    EntityPublication.publish(publication, items.epoch, :items, items.views)
    send_after_epoch(items.epoch, :commit, RegionStorage.commit_ms())

    %__MODULE__{
      key: key,
      items: items,
      item_receipts: loaded.receipts,
      containers: loaded.containers,
      block_entities: block_entities,
      container_viewers: %ContainerViewers{},
      cooking_progress: %{},
      cooking: %CookingRuntime{enabled: Valimc.config(:cooking_simulation, key)},
      cooking_orbs: %CookingOrbRuntime{},
      item_storage_enabled: loaded.persistent,
      item_publication: publication,
      item_pending: nil,
      item_handoff: nil,
      item_simulation: nil,
      item_portal: nil,
      item_simulation_enabled: Valimc.config(:item_simulation, key),
      item_merge_stamp: nil,
      item_merge_next: nil,
      item_cross_job: nil,
      item_cross_next: nil,
      item_cross_stamp: nil,
      item_cross_scan_stamp: nil,
      item_cross_cursor: nil,
      item_cross_retry: false,
      item_resting: %{},
      permits: Valimc.Txn.Permits.new(),
      blocks: blocks,
      cache: %{},
      jobs: %{},
      versions: %{},
      served: MapSet.new(),
      generation: generation,
      tickets: Tickets.new(0),
      idle_since: nil,
      revision: 0,
      section_revisions: %{},
      game_tick: loaded.game_tick,
      orb_age_ticks: 0,
      item_age_debt: 0,
      scheduled_ticks: scheduled,
      tick_index: tick_index,
      rule_backlog: [],
      random_tick_speed: Valimc.config(:random_tick_speed, key),
      storage: storage
    }
    |> baseline_storage()
    |> resume_item_handoff()
  end

  defp send_after_epoch(epoch, message, ms),
    do: Process.send_after(self(), {:resource, epoch, message}, ms)

  @doc "The owner's keyed parts that `RegionStorage` diffs into frames and checkpoints."
  def parts(state),
    do: %{
      items: state.items,
      receipts: state.item_receipts,
      containers: state.containers,
      ticks: state.scheduled_ticks,
      block_entities: state.block_entities,
      game_tick: state.game_tick
    }

  defp baseline_storage(state),
    do: %{state | storage: RegionStorage.baseline(state.storage, parts(state))}

  def item_tick(state, now) do
    state = travel_item(state)
    if Tickets.simulating?(state.tickets), do: simulate_items(state, now), else: state
  end

  defp simulate_items(state, now) do
    # A planning worker's result replaces the item map, so ageing waits while one
    # runs; the skipped ticks are owed and applied at once, so despawn timing
    # never stalls.
    ticks = state.item_age_debt + 1

    {items, expired} =
      if state.item_simulation_enabled and state.item_pending == nil,
        do: Items.age(state.items, ticks),
        else: {nil, []}

    if items != nil and (expired == [] or write_busy(state) == nil) do
      state = remember_item_counters(%{state | item_age_debt: 0}, items)
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
      if state.item_simulation_enabled,
        do: %{state | item_age_debt: min(ticks, 6000)},
        else: state
    end
  end

  def cooking_tick(%{cooking: runtime} = state, now) do
    cond do
      not runtime.enabled or not state.item_storage_enabled or runtime.job != nil or
          write_busy(state) != nil ->
        state

      is_integer(runtime.retry_at) and now < runtime.retry_at and runtime.seen == nil ->
        state

      CookingRuntime.due?(runtime, state.containers, state.revision, state.items, now) ->
        start_cooking_plan(state, now)

      true ->
        state
    end
  end

  defp start_cooking_plan(state, now) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    containers = state.containers
    items = state.items
    # Workers get values: the blocks under every cooking container, not the storage handle.
    edits = Blocks.get_many(state.blocks, for({p, %{cooking: _}} <- containers.entries, do: p))
    key = state.key
    selection = CookingRuntime.selection(state.cooking, containers, state.revision, items, now)
    blocked = state.cooking.blocked

    case Task.Supervisor.start_child(
           Valimc.ItemWorkers,
           Valimc.Dimension.bind(fn ->
             result = CookingRuntime.plan(containers, items, key, edits, selection, blocked)
             send(owner, {:resource, epoch, {:cooking_plan, self(), token, result}})
           end)
         ) do
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
          Blocks.get(state.blocks, position) == block
        end)

    with true <- current,
         {:ok, items} <- Items.merge_created(state.items, job.items, plan.items) do
      plan = %{plan | items: items}

      if plan.changes == %{},
        do: finish_cooking(state, plan),
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
             CookingRuntime.lit_change?(Blocks.get(state.blocks, position), block)
           end), do: build_block_proposal(state, plan.batch), else: {:error, :invalid_cooking_lit}
      else
        {:ok, nil}
      end

    case result do
      {:ok, proposal} ->
        Valimc.Metrics.add(:cooking_commits)

        # Lit blocks, items and containers are adopted together; the next frame
        # holds them (VMC-077f).
        state =
          if plan.batch do
            {state, effects} = apply_blocks(state, plan.batch, proposal, true)
            release_blocks(state, effects)
          else
            state
          end

        finish_cooking(state, plan)

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

  # Viewers learn of progress at once; the next frame holds it.
  defp finish_cooking(state, plan) do
    now = System.monotonic_time(:millisecond)

    runtime =
      CookingRuntime.accepted(
        state.cooking,
        plan,
        plan.containers,
        state.revision,
        plan.items,
        now
      )

    publish_item_views(%{state | items: plan.items})

    state = %{
      state
      | containers: plan.containers,
        items: plan.items,
        cooking: runtime,
        cooking_progress: Map.take(state.cooking_progress, Map.keys(plan.containers.entries)),
        permits:
          Valimc.Txn.Permits.invalidate(state.permits, Map.new(plan.content, &{&1, nil}), [
            :mining,
            :placement
          ])
    }

    state = release_now(state, Enum.map(plan.content, &{:container_changed, &1}))

    Enum.reduce(plan.changed, state, fn position, state ->
      generation = Map.get(state.cooking_progress, position, 0) + 1

      {viewers, notices} =
        ContainerViewers.progressed(state.container_viewers, position, generation)

      deliveries =
        for {pid, ref, progress} <- notices,
            do:
              {:deliver, pid,
               {:container_progress, {self(), state.items.epoch}, ref, position, progress}}

      %{
        state
        | container_viewers: viewers,
          cooking_progress: Map.put(state.cooking_progress, position, generation)
      }
      |> release_now(deliveries)
    end)
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
                    # Bounds the worker's owner round trips (scaled in tests, VMC-073).
                    timer:
                      send_after(
                        state,
                        {:item_cross_deadline, token},
                        Valimc.Txn.Permits.window(750)
                      )
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
      publish_item_views(%{state | items: items})
      %{state | items: items}
    end
  end

  defp start_item_simulation(%{item_simulation: nil} = state, now) do
    inputs =
      for {id, %{entity: %{x: x, z: z}} = entry} <- state.items.entries,
          Tickets.simulated?(state.tickets, Valimc.World.chunk_key(x, z)),
          not resting_current?(state, id) do
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

  # A resting item is simulated again once a section around it changes.
  defp resting_fence(state, {x, y, z}) do
    {x, y, z} = {floor(x), floor(y), floor(z)}

    fence(
      state,
      for(dx <- [-1, 1], dy <- [-1, 1], dz <- [-1, 1], do: {x + dx, y + dy, z + dz})
      |> Enum.filter(&in_region?(state, &1))
    )
  end

  defp resting_current?(state, id) do
    case state.item_resting[id] do
      {version, fence} ->
        version == state.items.entries[id].physical_revision and fence_current?(state, fence)

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

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :expired_item_step}, state}

      true ->
        case PickupPermits.issue(
               state.permits,
               state.item_receipts,
               state.items,
               actor,
               item_uuid,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, grant} ->
            {:reply, {:ok, grant}, %{state | permits: permits}}

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

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      true ->
        {permits, grant, eligible} =
          PickupPermits.consume(
            state.permits,
            state.items,
            request,
            System.monotonic_time(:millisecond)
          )

        # This owner admits the decision now and freezes item mutations while
        # planning/persisting. Expiry after admission cannot change its ordering.
        effect = pickup_effect(state.items, request, grant, eligible)

        case plan_item_change(:item_pickup, {request, eligible, effect}, from, state) do
          {:noreply, next} -> {:noreply, %{next | permits: permits}}
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
        # A contact window like the item-merge permit's (VMC-073 scales it in tests).
        expires_at: System.monotonic_time(:millisecond) + Valimc.Txn.Permits.window(250)
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
          state.permits,
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
        {:noreply, next} -> {:noreply, %{next | permits: permits}}
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
         :ok <- ItemMergePermits.available?(state.permits, source, now) do
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
          state.permits,
          state.items,
          request,
          System.monotonic_time(:millisecond)
        )

      case plan_item_change(:cross_merge_in, {request, allowed}, from, state) do
        {:noreply, next} -> {:noreply, %{next | permits: permits}}
        reply -> reply
      end
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:owner_item_receipt, epoch, source}, from, state) do
    result =
      cond do
        epoch != state.items.epoch -> {:error, :stale_region}
        not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
        not Map.has_key?(state.items.ledger.incoming, source) -> {:error, :missing_item_receipt}
        true -> {:ok, {state.key, state.items.ledger.incoming[source]}}
      end

    {:noreply, reply_when_durable(state, from, result)}
  end

  def handle_call({:merge_items, epoch, pairs, deadline}, from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

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

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

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
              publish_item_views(%{state | items: items})
              {:reply, {:ok, handles}, %{state | items: items}}
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

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

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

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

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
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
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
        blocks = Map.new(positions, &{&1, Blocks.get(state.blocks, &1)})

        case MiningPermits.reserve(
               state.permits,
               blocks,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, token} ->
            {:reply, {:ok, %{permit: token, expected: blocks}}, %{state | permits: permits}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:renew_mining, epoch, permit}, _from, state) do
    if epoch == state.items.epoch do
      case MiningPermits.renew(state.permits, permit, System.monotonic_time(:millisecond)) do
        {:ok, permits, blocks} ->
          {:reply, {:ok, blocks}, %{state | permits: permits}}

        error ->
          {:reply, error, state}
      end
    else
      {:reply, {:error, :stale_owner}, state}
    end
  end

  def handle_call({:release_mining, epoch, permit}, _from, state) do
    if epoch == state.items.epoch,
      do: {:reply, :ok, %{state | permits: Valimc.Txn.Permits.release(state.permits, permit)}},
      else: {:reply, {:error, :stale_owner}, state}
  end

  def handle_call({:mining_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
      true -> plan_block_transfer(:mining, transfer, from, unpack_to_break(state, transfer))
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

      not fence_current?(state, revision) ->
        {:reply, {:error, :stale_revision}, state}

      not Enum.all?(expected, fn {{x, y, z}, block} ->
        Chunk.valid_y?(y) and Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key and
            Blocks.get(state.blocks, {x, y, z}) == block
      end) ->
        {:reply, {:error, :placement_context_changed}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        case PlacementPermits.reserve(
               state.permits,
               expected,
               System.monotonic_time(:millisecond)
             ) do
          {:ok, permits, token} ->
            {:reply, {:ok, %{permit: token, expected: expected}}, %{state | permits: permits}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:release_placement, epoch, permit}, _from, state) do
    if epoch == state.items.epoch,
      do: {:reply, :ok, %{state | permits: Valimc.Txn.Permits.release(state.permits, permit)}},
      else: {:reply, {:error, :stale_owner}, state}
  end

  def handle_call({:placement_transfer, epoch, transfer}, from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
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

  def handle_call({:container_transfer, epoch, request}, from, state) do
    container_request(state, epoch, fn ->
      containers = state.containers
      key = state.key
      block = container_block(state, request)

      {permits, grant} =
        ContainerPermits.take(state.permits, request, System.monotonic_time(:millisecond))

      state = %{state | permits: permits}

      start_container_work(state, from, :deliver, container_position(request), fn ->
        with {:ok, digest} <- ContainerRequest.digest(key, request),
             {:ok, reserved, _} <- ContainerTransfers.reserve(containers, request.source) do
          eligible =
            ContainerPermits.eligible?(grant, request, digest) and
              container_block_matches?(request, block)

          plan =
            if request[:kind] == :experience,
              do: Valimc.World.ExperienceTransfers.plan(reserved, key, request, eligible),
              else: ContainerTransfers.plan(reserved, key, request, eligible)

          plan
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
                 true <- container_admission_matches?(containers, request, actor),
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

  def handle_call({:container_transfer_receipt, epoch, source}, from, state) do
    result =
      cond do
        epoch != state.items.epoch -> {:error, :stale_region}
        not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
        not (is_binary(source) and byte_size(source) == 16) -> {:error, :invalid_transfer_source}
        state.containers.receipts[source] == nil -> {:error, :missing_container_receipt}
        true -> {:ok, {state.key, state.containers.receipts[source]}}
      end

    # A receipt is destination proof: it leaves only once durable.
    {:noreply, reply_when_durable(state, from, result)}
  end

  def handle_call({:item_transfer_receipt, epoch, source}, from, state) do
    result =
      cond do
        epoch != state.items.epoch -> {:error, :stale_region}
        not state.item_storage_enabled -> {:error, :transfer_storage_disabled}
        not (is_binary(source) and byte_size(source) == 16) -> {:error, :invalid_transfer_source}
        state.item_receipts[source] == nil -> {:error, :missing_transfer_receipt}
        true -> {:ok, {state.key, state.item_receipts[source]}}
      end

    {:noreply, reply_when_durable(state, from, result)}
  end

  def handle_call({:chunk, key} = message, from, state) do
    cond do
      Valimc.World.region_key(key) != state.key ->
        {:reply, {:error, :wrong_region}, state}

      RegionGeneration.absent?(state.generation, key) ->
        RegionGeneration.defer(state, key, message, from)

      true ->
        serve_chunk(%{state | served: MapSet.put(state.served, key)}, key, from)
    end
  end

  # Readers of published snapshots await generation instead of polling
  # (VMC-077e): the reply comes once every chunk of `chunks` is installed.
  def handle_call({:await_chunks, chunks} = message, from, state) do
    cond do
      Enum.any?(chunks, &(Valimc.World.region_key(&1) != state.key)) ->
        {:reply, {:error, :wrong_region}, state}

      chunk = Enum.find(chunks, &RegionGeneration.absent?(state.generation, &1)) ->
        RegionGeneration.defer(RegionGeneration.urgent(state, chunks), chunk, message, from)

      true ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:observe_blocks, epoch, positions, expected_revision}, _from, state) do
    result =
      cond do
        not valid_block_query?(positions, expected_revision) ->
          {:error, :invalid_block_query}

        epoch != state.items.epoch ->
          {:error, :stale_owner}

        not fence_current?(state, expected_revision) ->
          {:error, :stale_revision}

        Enum.any?(positions, fn {x, _, z} ->
          Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != state.key
        end) ->
          {:error, :wrong_region}

        absent_positions?(state, positions) ->
          {:error, :chunk_generating}

        true ->
          {:ok,
           %{
             owner: {self(), state.items.epoch},
             region: state.key,
             revision: state.revision,
             # The sections read: edits elsewhere in the region do not stale it.
             fence: fence(state, positions),
             blocks: Map.new(positions, &{&1, Blocks.get(state.blocks, &1)})
           }}
      end

    if result == {:error, :chunk_generating},
      do: {:reply, result, want_positions(state, positions)},
      else: {:reply, result, state}
  end

  # `/fillbiome` (VMC-053j4): the biome change applies at once and its column
  # images join the next frame like generated ones; viewers get `chunks_biomes`.
  def handle_call({:fill_biomes, epoch, chunks, box, biome, filter}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      Enum.any?(chunks, fn chunk -> Valimc.World.region_key(chunk) != state.key end) ->
        {:reply, {:error, :wrong_region}, state}

      absent_positions?(state, for({cx, cz} <- chunks, do: {cx * 16, 0, cz * 16})) ->
        {:reply, {:error, :chunk_generating}, state}

      true ->
        case Blocks.fill_biomes(state.blocks, chunks, box, biome, filter) do
          {:ok, {count, []}} ->
            {:reply, {:ok, count}, state}

          {:ok, {count, images}} ->
            columns = Map.new(images, fn {cx, cz, image} -> {{cx, cz}, image} end)
            state = %{state | storage: RegionStorage.columns(state.storage, columns)}
            changed = Map.keys(columns)
            biomes = Map.new(changed, &{&1, Blocks.encode_biomes(state.blocks, &1)})

            for {chunk, {:ok, bytes}} <- biomes,
                do: Valimc.World.publish(state.key, {:chunks_biomes, [{chunk, bytes}]})

            {:reply, {:ok, count}, light_changed(state, changed)}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  # `/place` (VMC-053): the column images of chunks of this region (`nil`
  # for the flat base profile), at the current revision; a chunk still
  # generating is not loaded.
  def handle_call({:column_images, epoch, chunks}, _from, state) do
    result =
      cond do
        epoch != state.items.epoch ->
          {:error, :stale_owner}

        Enum.any?(chunks, fn {cx, cz} -> Valimc.World.region_key({cx, cz}) != state.key end) ->
          {:error, :wrong_region}

        absent_positions?(state, for({cx, cz} <- chunks, do: {cx * 16, 0, cz * 16})) ->
          {:error, :chunk_generating}

        true ->
          images =
            Map.new(chunks, fn chunk ->
              case Blocks.column_image(state.blocks, chunk) do
                {:ok, image} when is_binary(image) -> {chunk, image}
                _ -> {chunk, nil}
              end
            end)

          {:ok, %{revision: state.revision, images: images}}
      end

    {:reply, result, state}
  end

  def handle_call({:light_image, epoch, chunk}, _from, %{items: %{epoch: epoch}} = state),
    do: {:reply, Blocks.light_image(state.blocks, chunk), state}

  def handle_call({:destroy_block, epoch, revision, position, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not fence_current?(state, revision) ->
        {:reply, {:error, :stale_revision}, state}

      not (is_integer(deadline) and now < deadline and
               deadline <= now + Valimc.Txn.Permits.window(250)) ->
        {:reply, {:error, :expired_destruction}, state}

      absent_positions?(state, [position]) ->
        {:reply, {:error, :chunk_generating}, want_positions(state, [position])}

      true ->
        remove_block(state, position, from)
    end
  end

  def handle_call({:block_entity, epoch, position}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not valid_block_query?([position], :any) or not in_region?(state, position) ->
        {:reply, {:error, :invalid_block_query}, state}

      true ->
        entry =
          BlockEntities.live(state.block_entities, position, Blocks.get(state.blocks, position))

        {:reply, {:ok, entry && Map.take(entry, [:type, :nbt])}, state}
    end
  end

  # `/save-all flush`, tools and tests: everything adopted is durable and in
  # the checkpoint file when this returns.
  def handle_call(:flush, _from, state) do
    state = save_now(state)
    {:reply, :ok, state}
  end

  # Gateway exits (VMC-026b4): preserved entries join the set and the next
  # commit frame.
  def handle_call({:put_block_entities, epoch, entries}, _from, state) do
    positions = Map.keys(entries)

    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not valid_block_query?(positions, :any) or not Enum.all?(positions, &in_region?(state, &1)) ->
        {:reply, {:error, :invalid_block_query}, state}

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      true ->
        case BlockEntities.put(state.block_entities, entries, &Blocks.get(state.blocks, &1)) do
          {:ok, entities, _stored} ->
            {:reply, {:ok, :applied}, %{state | block_entities: entities}}

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:block_entity_update, epoch, position}, _from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_owner}, state}
      not valid_block_query?([position], :any) -> {:reply, {:error, :invalid_block_query}, state}
      true -> {:reply, {:ok, preserved_update(state, position)}, state}
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

  def handle_call({:set_blocks, epoch, revision, %BlockBatch{} = batch}, from, state),
    do: handle_call({:set_blocks, epoch, revision, batch, MapSet.new()}, from, state)

  def handle_call({:set_blocks, epoch, revision, %BlockBatch{} = batch, entities}, _from, state) do
    cond do
      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      not fence_current?(state, revision) ->
        {:reply, {:error, :stale_revision}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      true ->
        case block_proposal(state, batch, [], entities) do
          {:ok, proposal} ->
            next = publish_blocks(state, batch, proposal)
            {:reply, {:ok, next.revision}, next}

          error ->
            {:reply, error, state}
        end
    end
  end

  # ---- box edits (VMC-077o) ----
  #
  # `/setblock`, `/fill`, `/clone` and `/place` read boxes (`:read_box`, never
  # generating an absent chunk: that is an unloaded position) and commit their
  # edits in every owner they touch all or nothing (`Valimc.World.BoxEdit`):
  # each owner first checks that the cells it was planned on still hold the
  # states read, that it can commit the edits (and block entity records), and
  # locks the cells (`Txn.Permits` `:box_edit`); the commit follows once every
  # owner prepared, and an abort releases the lock.

  def handle_call({:read_box, epoch, min, max}, _from, state) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_owner}, state}
      not box_in_region?(state, min, max) -> {:reply, {:error, :wrong_region}, state}
      box_absent?(state, min, max) -> {:reply, {:error, :chunk_generating}, state}
      true -> {:reply, Blocks.read_box(state.blocks, min, max), state}
    end
  end

  def handle_call({:prepare_box, epoch, token, edits, expected, entries}, _from, state) do
    now = System.monotonic_time(:millisecond)
    positions = Enum.uniq(Map.keys(edits) ++ Map.keys(expected))
    entities = MapSet.new(Map.keys(entries))

    planned = fn position ->
      Map.get_lazy(edits, position, fn -> Blocks.get(state.blocks, position) end)
    end

    result =
      cond do
        epoch != state.items.epoch ->
          {:error, :stale_owner}

        not Enum.all?(positions, &owns?(state, &1)) ->
          {:error, :wrong_region}

        absent_positions?(state, positions) ->
          {:error, :chunk_generating}

        Blocks.get_many(state.blocks, Map.keys(expected)) != expected ->
          {:error, :stale_revision}

        true ->
          with {:ok, batch} <- BlockBatch.prepare(edits),
               {:ok, _proposal} <- block_proposal(state, batch, [], entities),
               {:ok, _, _} <- BlockEntities.put(state.block_entities, entries, planned) do
            grant = %{batch: batch, entities: entities, cells: MapSet.new(Map.keys(edits))}
            Permits.issue(state.permits, :box_edit, token, self(), [], grant, now)
          end
      end

    case result do
      {:ok, permits, ^token} -> {:reply, :ok, %{state | permits: permits}}
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :unsupported_block_entity}, state}
    end
  end

  # A transient write in flight answers `:retry` and keeps the lock.
  def handle_call({:commit_box, epoch, token, entries}, from, state) do
    now = System.monotonic_time(:millisecond)

    case Permits.lookup(state.permits, :box_edit, token, now) do
      {:ok, grant} when epoch == state.items.epoch ->
        if block_transfer_writing?(state) or (entries != %{} and write_busy(state) != nil) do
          {:reply, {:error, :retry}, state}
        else
          state = %{state | permits: Permits.release(state.permits, token)}

          case block_proposal(state, grant.batch, [], grant.entities) do
            {:ok, proposal} ->
              next = publish_blocks(state, grant.batch, proposal)

              if entries == %{},
                do: {:reply, {:ok, :applied}, next},
                else: handle_call({:put_block_entities, epoch, entries}, from, next)

            error ->
              {:reply, error, state}
          end
        end

      _ ->
        {:reply, {:error, :box_edit_expired}, state}
    end
  end

  def handle_call({:abort_box, token}, _from, state),
    do: {:reply, :ok, %{state | permits: Permits.release(state.permits, token)}}

  def handle_call({:place_block, epoch, revision, %BlockBatch{} = batch, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    expected =
      Map.new(batch.edits, fn {position, _} ->
        {position, Blocks.get(state.blocks, position)}
      end)

    cond do
      not (is_integer(deadline) and deadline > now and
             deadline <= now + Valimc.Txn.Permits.window(250) and
               map_size(batch.edits) == 1) ->
        {:reply, {:error, :invalid_or_expired_placement}, state}

      not container_metadata_affected?(state.containers, expected, batch.edits) ->
        handle_call({:set_blocks, epoch, revision, batch}, from, state)

      epoch != state.items.epoch ->
        {:reply, {:error, :stale_owner}, state}

      not fence_current?(state, revision) ->
        {:reply, {:error, :stale_revision}, state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      not state.item_storage_enabled ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      not isolated_chest_changes?(state, batch) ->
        {:reply, {:error, :unsupported_chest_neighbors}, state}

      true ->
        start_container_blocks(state, from, batch, expected)
    end
  end

  # One block set inside a fenced destruction (`remove_block/3`).
  defp set_block(state, {x, y, z} = position, block) do
    key = Valimc.World.chunk_key(x, z)

    cond do
      Permits.locked?(state.permits, [position], System.monotonic_time(:millisecond)) ->
        {:reply, {:error, :box_edit_pending}, state}

      block_transfer_writing?(state) ->
        {:reply, {:error, :mining_storage_busy}, state}

      protected_container_change?(state, %{position => block}) ->
        {:reply, {:error, :occupied_container}, state}

      preserved_change?(state, %{position => block}) ->
        {:reply, {:error, :unsupported_block_entity}, state}

      true ->
        previous_blocks = Blocks.get_many(state.blocks, [position])

        if Valimc.World.region_key(key) == state.key and Chunk.valid_y?(y) and block >= 0 and
             block < Valimc.Protocol.Data.block_state_count() and
             Blocks.put(state.blocks, %{position => block}) == :ok do
          lit = Blocks.light_update(state.blocks, [position])

          state =
            state
            |> light_changed(Blocks.changed_chunks(lit) -- [key])
            |> release_effect({:raw_block, position, block, previous_blocks, lit})

          next =
            %{
              state
              | storage: RegionStorage.cells(state.storage, %{position => block}),
                permits: Valimc.Txn.Permits.invalidate(state.permits, %{position => block}),
                revision: state.revision + 1,
                section_revisions: touch_sections(state, [position], state.revision + 1),
                versions: Map.update(state.versions, key, 1, &(&1 + 1))
            }
            |> uncache([key])
            |> shape_updates(previous_blocks)

          {:reply, :ok, publish_block_snapshots(next, [key])}
        else
          {:reply, {:error, :invalid_block}, state}
        end
    end
  end

  defp remove_block(state, position, from) do
    block = Blocks.get(state.blocks, position)
    replacement = Valimc.Block.after_removal(block)

    state =
      if in_region?(state, position) and write_busy(state) == nil,
        do: unpack_loot(state, position, 0.0),
        else: state

    if Valimc.Block.block_entity(block) != nil and
         Map.has_key?(state.containers.entries, position) do
      if busy = write_busy(state) do
        {:reply, {:error, busy}, state}
      else
        with {:ok, batch} <- BlockBatch.prepare(%{position => replacement}),
             do: start_container_blocks(state, from, batch, %{position => block}, :ok),
             else: (error -> {:reply, error, state})
      end
    else
      set_block(state, position, replacement)
    end
  end

  defp serve_chunk(state, key, from) do
    cond do
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

  ## Durability (VMC-077f)

  # Cut a frame of what changed since the last; replies and effects whose frame
  # was already durable (none here) run at once.
  defp commit(state) do
    {storage, released} = RegionStorage.commit(state.storage, parts(state))
    run_released(%{state | storage: storage}, released)
  end

  # Commit, wait until the frames are appended, then checkpoint here.
  defp save_now(%{storage: %{base: nil}} = state), do: commit(state)

  defp save_now(state) do
    state = commit(state)
    :ok = Valimc.Storage.Log.sync(state.storage.base, state.storage.owner)
    state = drain_durable(state)

    if Valimc.World.Saving.auto?(),
      do: %{
        state
        | storage: RegionStorage.checkpoint(state.storage, parts(state), state.blocks, sync: true)
      },
      else: state
  end

  # Durable acknowledgements already in the mailbox (after a sync).
  defp drain_durable(state) do
    receive do
      {:storage_durable, seq} ->
        {:noreply, state} = durable(state, seq)
        drain_durable(state)
    after
      0 -> state
    end
  end

  defp durable(state, seq) do
    {storage, released} = RegionStorage.durable(state.storage, seq)
    {:noreply, maybe_checkpoint(run_released(%{state | storage: storage}, released))}
  end

  defp maybe_checkpoint(state) do
    if RegionStorage.checkpoint_due?(state.storage),
      do: %{state | storage: RegionStorage.checkpoint(state.storage, parts(state), state.blocks)},
      else: state
  end

  defp run_released(state, items) do
    Enum.reduce(items, state, fn
      {:reply, from, reply}, acc ->
        finish_item_reply(acc, from, reply)

      {:effect, effect}, acc ->
        release_effect(acc, effect)
    end)
  end

  # A reply a cross-owner transfer step depends on (a receipt, an applied
  # delivery) waits for its frame to be durable; everything else replies now.
  # Their frame is cut at once rather than at the next commit tick.
  defp reply_when_durable(state, from, reply), do: wait_durable(state, [{:reply, from, reply}])

  @doc false
  def wait_durable(state, waits) do
    storage = Enum.reduce(waits, state.storage, &RegionStorage.after_durable(&2, &1))
    commit(%{state | storage: storage})
  end

  defp release_now(state, effects), do: Enum.reduce(effects, state, &release_effect(&2, &1))

  @doc """
  The block phases of one region tick (VMC-066): scheduled ticks due at `tick`,
  then random ticks. Effects from behaviours apply as one raw batch.
  """
  def block_ticks(state, tick) do
    state = %{state | game_tick: tick}
    # Only chunks a simulation ticket covers tick; due ticks elsewhere wait.
    {due, scheduled} =
      ScheduledTicks.take_due(state.scheduled_ticks, tick, fn {x, _, z} ->
        Tickets.simulated?(state.tickets, Valimc.World.chunk_key(x, z))
      end)

    state = %{state | scheduled_ticks: scheduled}
    state = retry_rule_backlog(state)
    read = &read_block(state, &1)

    # A tick a behaviour handles runs it; the others are dependent blocks'
    # (VMC-029c), which the block rules break if they can no longer survive.
    {behaviour_due, rule_due} =
      due
      |> Enum.filter(fn {position, block} -> Blocks.get(state.blocks, position) == block end)
      |> Enum.split_with(fn {_, block} ->
        module = state.tick_index[block]
        module != nil and function_exported?(module, :scheduled_tick, 4)
      end)

    scheduled_effects =
      for {position, block} <- behaviour_due,
          effect <- state.tick_index[block].scheduled_tick(position, block, read, &random/1),
          do: effect

    {random_effects, state} = random_ticks(state, read)

    state
    |> rule_updates(%{}, rule_due)
    |> apply_tick_effects(scheduled_effects ++ random_effects)
  end

  @orb_save_ticks 600

  @doc """
  Orb lifetime (VMC-067): orbs age with the region tick; ages accumulate in
  memory and are written when an orb reaches 6000 ticks (it despawns) or every
  30 s. Runs only when no planning worker holds a container snapshot.
  """
  def orb_lifetime(
        %{containers: %{cooking_orbs: births, orb_transfers: %{incoming: incoming}}} = state
      )
      when map_size(births) == 0 and map_size(incoming) == 0,
      do: %{state | orb_age_ticks: 0}

  def orb_lifetime(state) do
    pending = state.orb_age_ticks + 1

    due =
      pending >= 6000 - Valimc.World.CookingOrbBodies.oldest(state.containers) or
        pending >= @orb_save_ticks

    if not due or write_busy(state) != nil do
      %{state | orb_age_ticks: pending}
    else
      case Valimc.World.CookingOrbBodies.advance(state.containers, state.key, pending) do
        {:ok, :unchanged} ->
          %{state | orb_age_ticks: 0}

        {:ok, containers} ->
          %{state | containers: containers, orb_age_ticks: 0}

        {:error, reason} ->
          require Logger
          Logger.warning("Orb ageing refused: #{inspect(reason)}")
          %{state | orb_age_ticks: 0}
      end
    end
  end

  # Vanilla picks `randomTickSpeed` positions per section per tick (the gamerule,
  # `:random_tick_speed`); the native sampler skips sections without handled
  # states and returns only hits.
  defp random_ticks(%{tick_index: index} = state, _read) when map_size(index) == 0,
    do: {[], state}

  defp random_ticks(state, read) do
    effects =
      for {{x, _, z} = position, block} <-
            Blocks.random_ticks(state.blocks, state.random_tick_speed),
          Tickets.simulated?(state.tickets, Valimc.World.chunk_key(x, z)),
          in_region?(state, position),
          module = state.tick_index[block],
          effect <- module.random_tick(position, block, read, &random/1),
          do: effect

    {effects, state}
  end

  defp random(bound), do: :rand.uniform(bound) - 1

  # Vanilla's updates after a block commit (VMC-077m): behaviours with effects
  # of their own (portals) schedule from here; everything else is the block
  # rules'. `previous` holds the changed cells' old states.
  defp shape_updates(state, previous) do
    state
    |> behaviour_shape_updates(Map.keys(previous))
    |> rule_updates(previous, [])
  end

  defp behaviour_shape_updates(%{tick_index: index} = state, _positions)
       when map_size(index) == 0,
       do: state

  defp behaviour_shape_updates(state, changed) do
    read = &read_block(state, &1)

    positions =
      for {x, y, z} <- changed,
          position <- [
            {x, y, z},
            {x, y - 1, z},
            {x, y + 1, z},
            {x, y, z - 1},
            {x, y, z + 1},
            {x - 1, y, z},
            {x + 1, y, z}
          ],
          in_region?(state, position),
          uniq: true,
          do: position

    effects =
      for {position, block} <- Blocks.get_many(state.blocks, positions),
          module = state.tick_index[block],
          module != nil and function_exported?(module, :shape_update, 4),
          {:schedule, _, _, _, _} = effect <-
            module.shape_update(position, block, read, &random/1),
          do: effect

    schedule_ticks(state, effects)
  end

  # The block rules after `previous` (cell => old state) changed and at
  # dependent blocks' due `ticks`. Their writes commit as one batch, with the
  # loot of the blocks they destroyed, in the next frame; that batch starts no
  # updates of its own. Behind a planning transfer a run with drops waits for
  # the next tick, whole.
  defp rule_updates(state, previous, []) when map_size(previous) == 0, do: state

  defp rule_updates(state, previous, ticks) do
    absent = MapSet.to_list(state.generation.absent)
    outcome = Rules.run(state.blocks, previous, ticks, absent)
    drops = for {position, block, true} <- outcome.destroyed, do: {position, block}

    cond do
      drops != [] and write_busy(state) != nil ->
        %{state | rule_backlog: [{previous, ticks} | state.rule_backlog]}

      true ->
        changes = Map.new(outcome.changes)

        state
        |> schedule_ticks(rule_ticks(state, changes, outcome.ticks))
        |> commit_rule_changes(changes, drops)
    end
  end

  # The rules schedule a block's tick, as vanilla does; the owner's ticks name
  # the state, so each takes the cell's state after the run when it is that
  # block's (else vanilla's tick would not run either).
  defp rule_ticks(_state, _changes, []), do: []

  defp rule_ticks(state, changes, ticks) do
    ticks = Enum.filter(ticks, fn {position, _, _} -> in_region?(state, position) end)

    stored =
      Blocks.get_many(state.blocks, for({p, _, _} <- ticks, not is_map_key(changes, p), do: p))

    for {position, block, delay} <- ticks,
        cell = Map.get(changes, position) || Map.fetch!(stored, position),
        Valimc.Registry.Blocks.block_id(cell) == block,
        do: {:schedule, position, cell, delay, 0}
  end

  defp retry_rule_backlog(%{rule_backlog: []} = state), do: state

  defp retry_rule_backlog(state) do
    if write_busy(state) != nil do
      state
    else
      backlog = Enum.reverse(state.rule_backlog)

      Enum.reduce(backlog, %{state | rule_backlog: []}, fn {previous, ticks}, acc ->
        rule_updates(acc, previous, ticks)
      end)
    end
  end

  defp commit_rule_changes(state, edits, _drops) when map_size(edits) == 0, do: state

  defp commit_rule_changes(state, edits, []) do
    with {:ok, batch} <- BlockBatch.prepare(edits),
         {:ok, proposal} <- block_proposal(state, batch) do
      publish_blocks(state, batch, proposal, false, false)
    else
      _ -> state
    end
  end

  # Destroyed blocks break like vanilla `destroyBlock`: they leave their fluid
  # and drop their tool-less loot, in the frame that writes the rules' changes.
  defp commit_rule_changes(state, edits, drops) do
    items = Enum.reduce(drops, state.items, &add_support_drops(&2, state.key, &1))

    with {:ok, batch} <- BlockBatch.prepare(edits),
         {:ok, proposal} <- block_proposal(state, batch) do
      {state, effects} = apply_blocks(state, batch, proposal, false, false)
      state = %{state | items: items}
      publish_item_views(state)

      state
      |> release_blocks(effects)
      |> release_effect({:level_events, for({p, b} <- drops, do: {p, 2001, b})})
    else
      _ -> state
    end
  end

  # Loot rules this tool-less break cannot evaluate yet drop nothing. Each stack
  # pops like vanilla `Block.popResource` (javap of the pinned `Block` and
  # `ItemEntity`): up to 0.25 off the block centre, lowered by half the item's
  # 0.25 height, launched at (±0.1, 0.2, ±0.1) with a 10-tick pickup delay.
  defp add_support_drops(items, key, {{x, y, z}, block}) do
    stacks =
      case Valimc.Physics.MiningLoot.drops(block, nil, true) do
        {:ok, stacks} -> stacks
        {:error, _} -> []
      end

    Enum.reduce(stacks, items, fn stack, acc ->
      [dx, dy, dz, vx, vz] = for _ <- 1..5, do: :rand.uniform_real()

      record = %{
        uuid: :crypto.strong_rand_bytes(16),
        x: x + 0.5 + (dx * 0.5 - 0.25),
        y: y + 0.5 + (dy * 0.5 - 0.25) - 0.125,
        z: z + 0.5 + (dz * 0.5 - 0.25),
        stack: stack,
        motion: %Valimc.ItemMotionState{
          velocity: {vx * 0.2 - 0.1, 0.2, vz * 0.2 - 0.1},
          pickup_delay: 10
        }
      }

      case Items.create_record(acc, key, record) do
        {:ok, next, _} -> next
        {:error, _} -> acc
      end
    end)
  end

  defp read_block(state, position) do
    if in_region?(state, position), do: Blocks.get(state.blocks, position)
  end

  # A chunk not generated yet is outside, like a neighbour region's (VMC-075).
  defp in_region?(state, {x, y, z}) do
    chunk = Valimc.World.chunk_key(x, z)

    Valimc.World.region_key(chunk) == state.key and Chunk.valid_y?(y) and
      not RegionGeneration.absent?(state.generation, chunk)
  end

  defp absent_positions?(state, positions),
    do:
      RegionGeneration.any_absent?(
        state.generation,
        Enum.map(positions, fn {x, _, z} -> Valimc.World.chunk_key(x, z) end)
      )

  defp want_positions(state, positions),
    do:
      RegionGeneration.urgent(
        state,
        positions |> Enum.map(fn {x, _, z} -> Valimc.World.chunk_key(x, z) end) |> Enum.uniq()
      )

  defp apply_tick_effects(state, []), do: state

  defp apply_tick_effects(state, effects) do
    state = schedule_ticks(state, effects)
    edits = for {:set, position, block} <- effects, into: %{}, do: {position, block}

    with true <- map_size(edits) > 0,
         {:ok, batch} <- BlockBatch.prepare(edits),
         {:ok, proposal} <- block_proposal(state, batch) do
      publish_blocks(state, batch, proposal)
    else
      _ -> state
    end
  end

  defp schedule_ticks(state, effects) do
    Enum.reduce(effects, state, fn
      {:schedule, position, block, delay, priority}, acc ->
        case ScheduledTicks.schedule(
               acc.scheduled_ticks,
               position,
               block,
               acc.game_tick + delay,
               priority
             ) do
          {:ok, ticks} -> %{acc | scheduled_ticks: ticks}
          {:error, _} -> acc
        end

      _, acc ->
        acc
    end)
  end

  defp item_request(epoch, from, state, work) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
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

  # Items (and receipts) are adopted at once and the caller is answered at
  # once (D2); the next frame holds their records (VMC-077f).
  defp commit_items(items, reply, from, state),
    do: commit_items(items, reply, from, state, state.item_receipts)

  defp commit_items(items, reply, from, state, receipts) do
    state = %{state | items: items, item_receipts: receipts}
    publish_item_views(state)
    {:noreply, finish_item_reply(state, from, reply)}
  end

  # The same for a transfer step another owner acts on: the reply waits for
  # the frame that holds the change (and its receipt) to be durable.
  defp commit_transfer(items, reply, from, state, receipts) do
    state = %{state | items: items, item_receipts: receipts}
    publish_item_views(state)
    {:noreply, reply_when_durable(state, from, reply)}
  end

  @doc """
  Why a new durable mutation cannot start now: the planning slot is taken
  (`:item_storage_busy`, retryable). `nil` when it may start.
  """
  def write_busy(state), do: if(state.item_pending != nil, do: :item_storage_busy)

  defp release_effect(state, {:blocks, effects}), do: release_blocks(state, effects)
  # Only the resume registered with the current outgoing record acts: a newer
  # record has its own, released once that record is durable.
  defp release_effect(state, {:resume_item_handoff, outgoing}) do
    if state.items.ledger.outgoing == outgoing, do: resume_item_handoff(state), else: state
  end

  defp release_effect(state, {:proto_handed_over, chunks}) do
    Valimc.Worldgen.Proto.handed_over(state.key, chunks)
    state
  end

  defp release_effect(state, {:deliver, pid, message}) do
    Valimc.Connection.deliver(pid, message)
    state
  end

  defp release_effect(state, {:level_events, events}) do
    Valimc.World.publish(state.key, {:level_events, events})
    state
  end

  defp release_effect(state, {:cooking_orbs, durable}),
    do: CookingOrbRuntime.durable(state, durable)

  defp release_effect(state, {:raw_block, position, block, previous, lit}) do
    state = retire_container_changes(state, %{position => block}, previous)
    Valimc.World.publish(state.key, {:block, position, block})

    if lit != [],
      do:
        Valimc.World.publish(
          state.key,
          {:block_batch, Valimc.World.LightHalo.frames(state, lit, :border)}
        )

    Valimc.World.LightHalo.forward(state, %{position => block})
    Valimc.Metrics.add(:block_edits)
    state
  end

  defp release_effect(state, {:container_changed, position}),
    do: notify_container_changed(state, position)

  defp release_effect(state, {:experience_pickup, request}) do
    case Enum.find(state.cooking_orbs.views, fn {_, v} -> v.uuid == request.orb_uuid end) do
      {id, _} ->
        Valimc.World.publish(
          state.key,
          {:experience_pickup, state.items.epoch, id, request.collector}
        )

      _ ->
        :ok
    end

    state
  end

  defp publish_item_views(state),
    do:
      EntityPublication.publish(
        state.item_publication,
        state.items.epoch,
        :items,
        state.items.views
      )

  defp plan_transfer(transfer, from, state),
    do: plan_item_change(:item_transfer, transfer, from, state)

  defp container_request(state, epoch, start) do
    cond do
      epoch != state.items.epoch -> {:reply, {:error, :stale_region}, state}
      not state.item_storage_enabled -> {:reply, {:error, :transfer_storage_disabled}, state}
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
      true -> start.()
    end
  end

  defp container_block(state, %{position: position}) do
    if valid_block_query?([position], :any) and
         Valimc.World.region_key(Valimc.World.chunk_key(elem(position, 0), elem(position, 2))) ==
           state.key,
       do: Blocks.get(state.blocks, position),
       else: nil
  end

  defp container_block(_, _), do: nil

  defp container_position(%{position: position}), do: position
  defp container_position(_), do: nil

  defp container_access(_state, %{kind: :experience, source: source}, %{
         uuid: source,
         game_mode: %{current: mode},
         health: %{value: hp},
         expires: expires
       })
       when mode in [:survival, :adventure, :creative] and hp > 0 do
    if System.monotonic_time(:millisecond) < expires,
      do: :ok,
      else: {:error, :expired_experience_contact}
  end

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
         (request[:award] == nil or request.award.position == actor[:position]) and
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

  defp container_admission_matches?(containers, %{kind: :experience} = request, actor),
    do:
      Valimc.World.ExperienceTransfers.eligible?(
        containers,
        request,
        actor,
        System.monotonic_time(:millisecond)
      )

  defp container_admission_matches?(containers, request, _actor),
    do:
      match?({:ok, _}, Valimc.World.Containers.observe(containers, request.position)) and
        ContainerRequest.matches_entry?(request, containers.entries[request.position])

  defp container_block_matches?(%{kind: :experience}, _), do: true
  defp container_block_matches?(%{rows: _}, block), do: Valimc.ChestAccess.single?(block)

  defp container_block_matches?(%{kind: kind}, block),
    do: Valimc.Physics.CookingBlocks.kind(block) == kind

  defp container_block_matches?(_, _), do: false

  # A container decision adopts its permits at once; the reply, viewer notices and
  # the orb pickup leave only once every write the decision read is durable.
  defp adopt_container_result(state, pending) do
    case {pending.operation, pending.decision.result} do
      {{:admit, actor}, {:admitted, request, digest}} ->
        with :ok <- container_access(state, request, actor),
             {:ok, permits} <-
               ContainerPermits.issue(
                 state.permits,
                 state.containers.receipts,
                 request,
                 digest,
                 System.monotonic_time(:millisecond)
               ) do
          {{:ok, request}, %{state | permits: permits}}
        else
          error -> {error, state}
        end

      {_, result} ->
        {{:ok, result}, state}
    end
  end

  defp container_effects(pending) do
    case Map.get(pending.decision, :experience) do
      nil -> [{:container_changed, pending.position}]
      request -> [{:container_changed, pending.position}, {:experience_pickup, request}]
    end
  end

  defp start_container_work(state, from, operation, position, work) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()

    case Task.Supervisor.start_child(
           Valimc.ItemWorkers,
           Valimc.Dimension.bind(fn ->
             result = work.()
             send(owner, {:resource, epoch, {:container_recovery_plan, self(), token, result}})
           end)
         ) do
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
      busy = write_busy(state) -> {:error, busy}
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

    case Task.Supervisor.start_child(
           Valimc.ItemWorkers,
           Valimc.Dimension.bind(fn ->
             result = item_plan(kind, items, receipts, key, request)
             send(owner, {:resource, epoch, {:item_transfer_plan, self(), token, result}})
           end)
         ) do
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

    case Valimc.Txn.Receipts.reserve(receipts, actor.uuid) do
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
    with {:ok, _} <- ItemMergeInbox.counter_plan(items, key, request, permitted),
         do: {:reply, {:item_merge_counters, request, permitted}}
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
    do: match?(%{kind: kind} when kind in [:container, :container_blocks], state.item_pending)

  defp permit_matches?(state, kind, %{permit: token, expected: expected}) do
    {module, permits} = permit_store(state, kind)
    module.lookup(permits, token, System.monotonic_time(:millisecond)) == {:ok, expected}
  end

  defp permit_matches?(_, _, _), do: false
  defp permit_store(state, :mining), do: {MiningPermits, state.permits}
  defp permit_store(state, :placement), do: {PlacementPermits, state.permits}
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

    case Task.Supervisor.start_child(
           Valimc.ItemWorkers,
           Valimc.Dimension.bind(fn ->
             result =
               with {:ok, plan} <- module.plan(items, receipts, key, transfer, eligible) do
                 plan = Map.put(plan, :kind, kind)

                 if plan.result == :applied do
                   changes =
                     if kind == :placement do
                       plan.edits
                     else
                       Map.new(plan.expected, fn {pos, block} ->
                         {pos, Valimc.Block.after_removal(block)}
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
           end)
         ) do
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
      Map.has_key?(containers.entries, position) or Valimc.Block.block_entity(block) != nil or
        Valimc.Block.block_entity(expected[position]) != nil
    end)
  end

  defp start_container_blocks(state, from, batch, expected, reply \\ :revision) do
    owner = self()
    epoch = state.items.epoch
    token = make_ref()
    containers = state.containers
    items = state.items
    key = state.key

    case Task.Supervisor.start_child(
           Valimc.ItemWorkers,
           Valimc.Dimension.bind(fn ->
             result =
               with {:ok, change} <-
                      ContainerLifecycle.plan(containers, key, expected, batch.edits),
                    {:ok, next} <- ContainerSpills.add(items, key, change.removed),
                    do: {:ok, Map.put(change, :items, next)}

             send(owner, {:resource, epoch, {:container_block_plan, self(), token, result}})
           end)
         ) do
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

  defp block_proposal(state, batch, removed \\ [], entities \\ MapSet.new()) do
    cond do
      Permits.locked?(state.permits, Map.keys(batch.edits), System.monotonic_time(:millisecond)) ->
        {:error, :box_edit_pending}

      protected_container_change?(state, batch.edits, removed) ->
        {:error, :occupied_container}

      preserved_change?(state, batch.edits) ->
        {:error, :unsupported_block_entity}

      # Without an owned record the block would be an empty, invisible shell,
      # unless the caller writes its record next.
      Enum.any?(batch.edits, fn {position, block} ->
        Valimc.Physics.BlockEntities.unsupported?(block) and
            not MapSet.member?(entities, position)
      end) ->
        {:error, :unsupported_block_entity}

      true ->
        build_block_proposal(state, batch)
    end
  end

  # Unrolled loot becomes the chest's contents before anything reads or removes
  # them (VMC-072b): the containers and the preserved entry's removal commit in
  # one frame, queued ahead of whatever follows, so replies wait for it.
  defp unpack_loot(state, position, luck) do
    block = Blocks.get(state.blocks, position)

    biome = fn ->
      {zoom_seed, _} = Generator.client_info()
      Blocks.biome(state.blocks, zoom_seed, position)
    end

    case LootChests.unpack(
           state.containers,
           state.block_entities,
           state.key,
           position,
           block,
           luck: luck,
           biome: biome
         ) do
      {:ok, containers, entities, _entry} ->
        Valimc.Metrics.add(:loot_unpacks)
        %{state | containers: containers, block_entities: entities}

      :error ->
        state
    end
  end

  # Vanilla unpacks when a player who may open the chest opens it: not a
  # spectator, and only where the open itself succeeds (`createMenu`). The
  # opener's luck attribute has no source in ValiMC yet, so it is 0.
  defp unpack_to_open(state, {x, y, z} = position, %{kind: :open, mode: mode} = grant)
       when mode != :spectator do
    block = Blocks.get(state.blocks, position)

    if write_busy(state) == nil and
         LootChests.unrolled?(state.containers, state.block_entities, position, block) do
      provisional = %{rows: 3, slots: Tuple.duplicate(nil, 27), revision: 0}
      above = Blocks.get(state.blocks, {x, y + 1, z})
      now = System.monotonic_time(:millisecond)

      case Valimc.ChestOpening.authorize(block, provisional, above, position, grant, now) do
        {:chest, _, _} -> unpack_loot(state, position, 0.0)
        _ -> state
      end
    else
      state
    end
  end

  defp unpack_to_open(state, _, _), do: state

  # Breaking a chest reads its contents to drop them, which unpacks it with no
  # player (luck 0), as `Containers.dropContents` does.
  defp unpack_to_break(state, %{expected: expected} = transfer) when is_map(expected) do
    if permit_matches?(state, :mining, transfer) do
      Enum.reduce(expected, state, fn {position, block}, acc ->
        if in_region?(acc, position) and Blocks.get(acc.blocks, position) == block and
             not Valimc.ChestAccess.single?(Valimc.Block.after_removal(block)),
           do: unpack_loot(acc, position, 0.0),
           else: acc
      end)
    else
      state
    end
  end

  defp unpack_to_break(state, _), do: state

  # An imported block entity holding data ValiMC cannot drop or spill keeps its
  # block (VMC-021e1).
  defp preserved_change?(state, changes),
    do: BlockEntities.protected?(state.block_entities, changes, &Blocks.get(state.blocks, &1))

  # Vanilla may consume a use of an imported block entity's block (signs, beds,
  # lecterns, double chests...); ValiMC cannot perform it, so it refuses rather
  # than placing against the block (VMC-021e1).
  defp preserved_use?(state, position, block),
    do:
      Valimc.Physics.BlockEntities.interactive?(block) and
        BlockEntities.live(state.block_entities, position, block) != nil

  # The update packet of a live imported block entity with an update tag, or nil.
  defp preserved_update(state, {x, _, z} = position) do
    with true <- Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key,
         %{type: type, update: update} when update != nil <-
           BlockEntities.live(state.block_entities, position, Blocks.get(state.blocks, position)) do
      Valimc.Protocol.ChestBlockEntity.data_packet(position, type, update)
    else
      _ -> nil
    end
  end

  # Live imported block entities of a chunk for its packet.
  defp preserved_entities(state, chunk) do
    case BlockEntities.in_chunk(state.block_entities, chunk) do
      [] ->
        []

      positions ->
        BlockEntities.chunk_entries(
          state.block_entities,
          chunk,
          Blocks.get_many(state.blocks, positions)
        )
    end
  end

  defp build_block_proposal(state, batch) do
    if RegionGeneration.any_absent?(state.generation, batch.chunks),
      do: {:error, :chunk_generating},
      else: build_present_proposal(state, batch)
  end

  defp build_present_proposal(state, batch) do
    versions =
      Enum.reduce(batch.chunks, state.versions, &Map.update(&2, &1, 1, fn n -> n + 1 end))

    {:ok,
     %{
       changes: batch.edits,
       versions: versions,
       revision: state.revision + 1
     }}
  end

  # Raw edits cannot orphan contents. Only a fully admitted spill proposal may
  # retire the exact owned entry in its joint block/item/container WAL.
  defp protected_container_change?(state, changes, removed \\ []) do
    retired = Map.new(removed, fn %{position: position, entry: entry} -> {position, entry} end)

    Enum.any?(changes, fn {position, block} ->
      case state.containers.entries[position] do
        %{cooking: _} = entry ->
          original = Blocks.get(state.blocks, position)

          block != original and
            not (retired[position] == entry and Valimc.World.CookingEntry.empty?(entry) and
                   Valimc.Physics.CookingBlocks.kind(original) == entry.kind and
                   Valimc.Physics.CookingBlocks.kind(block) != entry.kind)

        %{slots: slots} = entry ->
          block != Blocks.get(state.blocks, position) and
            Enum.any?(Tuple.to_list(slots), &(&1 != nil)) and
            not (retired[position] == entry and
                   Valimc.ChestAccess.single?(Blocks.get(state.blocks, position)) and
                   not Valimc.ChestAccess.single?(block))

        nil ->
          false
      end
    end)
  end

  # A block commit: adopted, logged in the next frame and sent to clients now.
  # `updates: false` (the block rules' own writes) starts no shape updates.
  defp publish_blocks(state, batch, proposal, cooking \\ false, updates \\ true) do
    {state, effects} = apply_blocks(state, batch, proposal, cooking, updates)
    release_blocks(state, effects)
  end

  # Memory side of a block commit: storage, fences, permits and caches, and the
  # cells for the next frame. External effects are returned for `release_blocks/2`.
  defp apply_blocks(state, batch, proposal, cooking, updates \\ true) do
    previous = Blocks.get_many(state.blocks, Map.keys(proposal.changes))
    :ok = Blocks.put(state.blocks, proposal.changes)

    chunks =
      Enum.uniq(
        Enum.map(Map.keys(proposal.changes), fn {x, _, z} -> Valimc.World.chunk_key(x, z) end)
      )

    state =
      state
      |> struct!(Map.take(proposal, [:versions, :revision]))
      |> then(
        &%{
          &1
          | section_revisions: touch_sections(&1, Map.keys(proposal.changes), proposal.revision)
        }
      )
      |> uncache(batch.chunks)
      |> Map.merge(%{
        storage: RegionStorage.cells(state.storage, proposal.changes),
        # Lit changes keep container grants: cooking does not change what a viewer sees.
        permits:
          Valimc.Txn.Permits.invalidate(
            state.permits,
            batch.edits,
            if(cooking, do: [:container], else: [])
          )
      })

    state = if cooking or not updates, do: state, else: shape_updates(state, previous)
    # Light follows every change, cooking too (a lit furnace emits light).
    lit = Blocks.light_update(state.blocks, Map.keys(proposal.changes))
    # Edited chunks were invalidated with their blocks above; others only lit.
    state = light_changed(state, Blocks.changed_chunks(lit) -- batch.chunks)

    {state, %{batch: batch, previous: previous, chunks: chunks, cooking: cooking, light: lit}}
  end

  @doc """
  Chunks whose light changed without (necessarily) a block change: their cached
  packets are dropped and their version moves on, so an encode already running
  is discarded as stale (VMC-022c).
  """
  def light_changed(state, []), do: state

  def light_changed(state, chunks) do
    uncache(
      %{
        state
        | versions: Enum.reduce(chunks, state.versions, &Map.update(&2, &1, 1, fn n -> n + 1 end))
      },
      chunks
    )
  end

  # A chunk's packet changed (VMC-077e): its cached frame goes, and so does the
  # copy published for connections, in the same step that adopts the change.
  defp uncache(state, chunks) do
    for chunk <- chunks, do: :ets.delete(state.item_publication, {:frame, chunk})
    %{state | cache: Map.drop(state.cache, chunks)}
  end

  defp release_blocks(state, effects) do
    state =
      if effects.cooking,
        do: state,
        else: retire_container_changes(state, effects.batch.edits, effects.previous)

    light = Valimc.World.LightHalo.frames(state, Map.get(effects, :light, []), :border)

    # Clients relight from the light packets after the block updates; neighbours
    # relight their ring from the changed blocks.
    Valimc.World.publish(state.key, {:block_batch, effects.batch.frames ++ light})
    Valimc.World.LightHalo.forward(state, effects.batch.edits)
    Valimc.Metrics.add(:block_edits, map_size(effects.batch.edits))
    publish_block_snapshots(state, effects.chunks)
  end

  # Readers see changed chunks as soon as the owner adopts them (D2).
  defp publish_block_snapshots(state, chunks) do
    :ok =
      BlockSnapshot.publish_chunks(state.item_publication, state.blocks, chunks, state.revision)

    state
  end

  defp isolated_chest_changes?(state, batch) do
    Enum.all?(batch.edits, fn {position, block} ->
      if Valimc.ChestAccess.single?(block) and
           not Valimc.ChestAccess.single?(Blocks.get(state.blocks, position)) do
        Enum.all?(Valimc.Physics.ChestPlacement.neighbors(position), fn {x, _, z} = neighbor ->
          Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key and
            not Valimc.ChestAccess.ordinary?(
              Map.get(batch.edits, neighbor, Blocks.get(state.blocks, neighbor))
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
        Process.cancel_timer(pending.timer)

        {:noreply,
         reply_when_durable(%{state | item_pending: nil}, pending.from, {:ok, plan.result})}

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
            # Blocks, items and receipts are adopted and shown now; the reply
            # (the other owner's proof) waits for their frame.
            if state.item_pending, do: Process.cancel_timer(state.item_pending.timer)
            state = publish_blocks(state, plan.batch, proposal)

            state = %{
              state
              | item_pending: nil,
                containers: Map.get(plan, :containers, state.containers)
            }

            commit_transfer(plan.items, {:ok, :applied}, pending.from, state, plan.receipts)

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
    state = %{state | permits: Valimc.Txn.Permits.release(state.permits, plan.permit)}

    # The rejection receipt is the other owner's proof too. The planning slot
    # of the block operation is released first.
    if state.item_pending, do: Process.cancel_timer(state.item_pending.timer)

    commit_transfer(
      state.items,
      {:ok, :rejected},
      from,
      %{state | item_pending: nil},
      plan.receipts
    )
  end

  defp start_job(state, key) do
    job = state.jobs[key]

    if job.pid do
      state
    else
      owner = self()
      epoch = state.items.epoch
      token = make_ref()
      # Section encoding is a short NIF call on the owner; packet assembly and
      # compression run in the worker from these immutable binaries.
      started = System.monotonic_time(:microsecond)
      encoded = Blocks.encode(state.blocks, key)
      entities = if encoded == :flat, do: %{}, else: Blocks.chunk_entities(state.blocks, key)
      preserved = preserved_entities(state, key)
      light = Blocks.light_image(state.blocks, key)
      sections_microseconds = System.monotonic_time(:microsecond) - started
      version = Map.get(state.versions, key, 0)
      threshold = Valimc.config(:compression_threshold)

      case Task.Supervisor.start_child(
             Valimc.ChunkWorkers,
             Valimc.Dimension.bind(fn ->
               started = System.monotonic_time(:microsecond)

               packet =
                 if encoded == :flat,
                   do: Chunk.encode(key, %{}, light),
                   else: Chunk.packet(encoded, entities, preserved, light)

               frame = Packets.frame(packet, threshold)
               Valimc.Metrics.add(:chunks_encoded)

               Valimc.Metrics.add(
                 :chunk_encode_microseconds,
                 sections_microseconds + System.monotonic_time(:microsecond) - started
               )

               send(owner, {:resource, epoch, {:encoded, key, token, version, frame}})
             end)
           ) do
        {:ok, pid} ->
          job = Map.merge(job, %{pid: pid, monitor: Process.monitor(pid), token: token})
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
        Process.cancel_timer(pending.timer)
        state = %{state | item_pending: nil, containers: containers}
        {reply, state} = adopt_container_result(state, pending)

        # A replayed step may read a receipt whose frame is still in flight.
        waits =
          Enum.map(container_effects(pending), &{:effect, &1}) ++
            [{:reply, pending.from, reply}, resume_handoff(state)]

        {:noreply, wait_durable(state, waits)}

      {:error, _} = error ->
        Process.cancel_timer(pending.timer)
        GenServer.reply(pending.from, error)
        {:noreply, item_plan_failed(state, pending)}
    end
  end

  def handle_info({:container_recovery_plan, _, _, _}, state), do: {:noreply, state}

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
        Process.cancel_timer(pending.timer)
        state = %{state | item_pending: nil, items: items, item_receipts: receipts}
        # A cleared handoff is over once adopted; the next one starts from its resume.
        state = if kind == :item_handoff_clear, do: %{state | item_handoff: nil}, else: state
        publish_item_views(state)
        {:noreply, wait_durable(state, [{:reply, pending.from, reply}, resume_handoff(state)])}

      {:reply, reply} ->
        Process.cancel_timer(pending.timer)
        state = %{state | item_pending: nil}
        {:noreply, wait_durable(state, [{:reply, pending.from, reply}, resume_handoff(state)])}

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
    do: {:noreply, %{state | permits: Valimc.Txn.Permits.release(state.permits, token, source)}}

  def handle_info(
        {:item_simulation, worker, token, result},
        %{item_simulation: %{worker: worker, token: token} = job} = state
      ) do
    Process.cancel_timer(job.timer)
    Process.demonitor(job.monitor, [:flush])
    state = %{state | item_simulation: nil}

    case result do
      {:ok, %{steps: steps, refused: refused}} ->
        Valimc.Metrics.add(:item_simulation_refusals, length(refused))

        # Steps of items that changed meanwhile are dropped; block changes are
        # not fenced (VMC-077e): the next tick moves the item from what it sees.
        if state.item_pending == nil and System.monotonic_time(:millisecond) < job.deadline,
          do: commit_simulated_items(state, steps),
          else: {:noreply, state}

      {:error, _} ->
        Valimc.Metrics.add(:item_simulation_failures)
        {:noreply, state}
    end
  end

  def handle_info({:item_simulation, _, _, _}, state), do: {:noreply, state}

  def handle_info({:item_portal, token, result}, %{item_portal: %{token: token} = job} = state) do
    Process.demonitor(job.monitor, [:flush])

    case result do
      {:ok, target} ->
        {:noreply, travel_item(%{state | item_portal: %{job | target: target}})}

      other ->
        require Logger
        Logger.warning("Item portal destination unavailable: #{inspect(other, limit: 12)}")
        {:noreply, %{state | item_portal: nil}}
    end
  end

  def handle_info({:item_portal, _, _}, state), do: {:noreply, state}

  def handle_info({:release_item_merge, token, source}, state),
    do:
      {:noreply,
       %{
         state
         | permits: Valimc.Txn.Permits.release(state.permits, token, source)
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
    if write_busy(state) != nil do
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

  def handle_info({:halo, message}, state),
    do: {:noreply, Valimc.World.LightHalo.handle(message, state)}

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
            # The contents drop in this region: nothing another owner acts on.
            Process.cancel_timer(pending.timer)
            state = publish_blocks(%{state | item_pending: nil}, pending.batch, proposal)
            state = %{state | containers: containers}
            reply = if pending.reply == :ok, do: :ok, else: {:ok, state.revision}
            commit_items(items, reply, pending.from, state, pending.receipts)

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

  def handle_info({:item_commit_deadline, token}, %{item_pending: %{token: token}} = state),
    do: {:stop, :item_storage_timeout, state}

  def handle_info({:item_commit_deadline, _}, state), do: {:noreply, state}

  def handle_info({:encoded, key, token, version, frame}, state) do
    case state.jobs[key] do
      %{token: ^token} = job ->
        Process.demonitor(job.monitor, [:flush])

        if version == Map.get(state.versions, key, 0) do
          for from <- job.waiters, do: GenServer.reply(from, frame)
          # Connections read a published frame without asking (VMC-077e).
          :ets.insert(state.item_publication, {{:frame, key}, frame})

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
        %{item_portal: %{monitor: ref, worker: worker, target: nil}} = state
      ),
      do: {:noreply, %{state | item_portal: nil}}

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

  # The log stripe went down: frames in flight may or may not be durable.
  def handle_info({:DOWN, ref, :process, _, reason}, %{storage: %{stripe: {_, ref}}} = state) do
    case RegionStorage.stripe_down(state.storage, ref) do
      {:failed, _} -> {:stop, {:storage_failed, {:log_down, reason}}, state}
      {:ok, storage} -> {:noreply, %{state | storage: storage}}
    end
  end

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
        %{cooking_orbs: %{delivery: %{pid: worker, monitor: ref}}} = state
      ),
      do: CookingOrbDelivery.down(state)

  def handle_info(
        {:DOWN, ref, :process, worker, _},
        %{cooking_orbs: %{job: %{worker: worker, monitor: ref}}} = state
      ),
      do: CookingOrbRuntime.down(state)

  # Generation (VMC-075): job results, durable batches, retries and wants.
  def handle_info({:generated, ref, result}, state),
    do: {:noreply, RegionGeneration.generated(state, ref, result)}

  def handle_info(:generation_retry, state), do: {:noreply, RegionGeneration.retry(state)}

  def handle_info({:ticket, holder, type, center, chunks}, state) do
    chunks = Enum.filter(chunks, &(Valimc.World.region_key(&1) == state.key))
    tickets = Tickets.put(state.tickets, holder, type, center, chunks, state.game_tick)
    {:noreply, RegionGeneration.pump(%{state | tickets: tickets})}
  end

  def handle_info({:DOWN, ref, :process, pid, reason} = message, state) do
    with :error <- Tickets.down(state.tickets, ref),
         :no_reply <- RegionGeneration.proto_response(state, message),
         :error <- RegionGeneration.down(state, ref) do
      down(state, ref, pid, reason)
    else
      {:ok, %Tickets{} = tickets} -> {:noreply, %{state | tickets: tickets}}
      {:ok, state} -> {:noreply, state}
    end
  end

  def handle_info({:storage_durable, seq}, state), do: durable(state, seq)

  # A frame that may be torn: only the log's recovery and a reload continue.
  def handle_info({:storage_failed, _seq, reason}, state),
    do: {:stop, {:storage_failed, reason}, state}

  def handle_info({:checkpointed, ref, seq, result}, state),
    do:
      {:noreply, %{state | storage: RegionStorage.checkpointed(state.storage, ref, seq, result)}}

  def handle_info(:commit, state) do
    state = maybe_checkpoint(commit(state))
    send_after_epoch(state.items.epoch, :commit, RegionStorage.commit_ms())
    {:noreply, state}
  end

  # `/save-all`: a checkpoint once its frames are appended (`/save-off` pauses them).
  def handle_info({:save, :force}, state) do
    state = commit(%{state | storage: RegionStorage.request_checkpoint(state.storage)})
    {:noreply, maybe_checkpoint(state)}
  end

  def handle_info({:table_request, epoch, connection, ref, position, grant}, state)
      when is_pid(connection) and is_reference(ref) do
    state =
      if epoch == state.items.epoch and valid_block_query?([position], :any) and
           in_region?(state, position),
         do: unpack_to_open(state, position, grant),
         else: state

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
          block = Blocks.get(state.blocks, position)
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
                Blocks.get(state.blocks, {x, y + 1, z}),
                position,
                grant,
                now
              )

            preserved_use?(state, position, block) ->
              Valimc.TableAccess.refuse_use(block, position, grant, now)

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

  # A proto owner's answer to a generation request (VMC-075; `gen_server`
  # replies to `send_request/2` are tagged with the request's alias).
  def handle_info({[:alias | ref], _} = message, state) when is_reference(ref) do
    case RegionGeneration.proto_response(state, message) do
      {:ok, state} -> {:noreply, state}
      :no_reply -> {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # A monitored worker or viewer went down.
  defp down(state, ref, pid, reason) do
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

  # `previous` holds the blocks before `edits`; storage may already hold `edits`.
  defp retire_container_changes(state, edits, previous) do
    positions =
      for {position, block} <- edits, Map.fetch!(previous, position) != block, do: position

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
    do: valid_fence?(revision) and valid_block_positions?(positions, 0)

  # `:any`, a region-wide revision, or a section fence from an observation.
  defp valid_fence?(:any), do: true
  defp valid_fence?(revision) when is_integer(revision), do: revision >= 0

  defp valid_fence?(fence) when is_map(fence) and map_size(fence) <= 128,
    do:
      Enum.all?(fence, fn
        {{cx, sy, cz}, rev} ->
          is_integer(cx) and is_integer(sy) and is_integer(cz) and is_integer(rev)

        _ ->
          false
      end)

  defp valid_fence?(_), do: false

  # Section fencing (VMC-064): each 16x16x16 section remembers the region revision
  # of its last edit. An observation's fence holds those values for the sections
  # it read, so only edits to those sections stale it.
  defp section({x, y, z}),
    do: {Integer.floor_div(x, 16), Integer.floor_div(y, 16), Integer.floor_div(z, 16)}

  defp box_in_region?(state, {x0, _, z0} = min, {x1, _, z1} = max),
    do: owns?(state, min) and owns?(state, max) and x0 <= x1 and z0 <= z1

  # A position of this region (generated or not) within the build height.
  defp owns?(state, {x, y, z}),
    do: Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == state.key and Chunk.valid_y?(y)

  defp box_absent?(state, {x0, _, z0}, {x1, _, z1}) do
    chunks =
      for cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
          cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
          do: {cx, cz}

    RegionGeneration.any_absent?(state.generation, chunks)
  end

  defp fence(state, positions),
    do: Map.new(positions, &{section(&1), Map.get(state.section_revisions, section(&1), 0)})

  defp fence_current?(_state, :any), do: true
  defp fence_current?(state, revision) when is_integer(revision), do: revision == state.revision

  defp fence_current?(state, fence) when is_map(fence),
    do: Enum.all?(fence, fn {s, rev} -> Map.get(state.section_revisions, s, 0) == rev end)

  defp touch_sections(state, positions, revision),
    do: Enum.reduce(positions, state.section_revisions, &Map.put(&2, section(&1), revision))

  defp valid_block_positions?([], _), do: true

  defp valid_block_positions?([{x, y, z} | rest], count)
       when count < 128 and is_integer(x) and is_integer(y) and is_integer(z) do
    abs(x) < 30_000_000 and abs(z) < 30_000_000 and abs(y) <= 1_000_000 and
      valid_block_positions?(rest, count + 1)
  end

  defp valid_block_positions?(_, _), do: false

  defp send_after(state, message, delay),
    do: Process.send_after(self(), {:resource, state.items.epoch, message}, delay)

  # Writes are acknowledged in queue order (the writer is FIFO). Release the
  # head write's effects, then everything that waited on it.
  defp reply_item(nil, _), do: :ok
  defp reply_item({:deliver, pid}, message), do: Valimc.Connection.deliver(pid, message)
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
            state.permits,
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
        %{state | permits: permits}

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
            state.permits,
            state.items.ledger.incoming,
            request,
            now
          ),
        else: {:error, :expired_item_step}

    case result do
      {:ok, permits, request} ->
        reply_item(from, {:ok, request})
        %{state | permits: permits}

      error ->
        reply_item(from, error)
        state
    end
  end

  # The counters apply to the items as they are when the reply is released: a reply
  # held behind an earlier write must not restore the items its plan saw.
  defp finish_item_reply(state, from, {:item_merge_counters, request, permitted}) do
    items =
      case ItemMergeInbox.counter_plan(state.items, state.key, request, permitted) do
        {:ok, items} -> items
        {:error, _} -> state.items
      end

    reply_item(from, {:ok, if(items == state.items, do: :unchanged, else: :applied)})

    if items == state.items do
      state
    else
      publish_item_views(%{state | items: items})
      %{state | items: items}
    end
  end

  defp finish_item_reply(state, from, reply) do
    reply_item(from, reply)
    state
  end

  defp commit_simulated_items(state, steps) do
    steps =
      Enum.flat_map(steps, fn step ->
        case state.items.entries[step.id] do
          %{motion: counters, physical_revision: revision} = entry
          when revision == step.physical_revision ->
            [
              %{
                step
                | revision: entry.revision,
                  motion: %{
                    step.motion
                    | age: counters.age,
                      pickup_delay: counters.pickup_delay,
                      portal_cooldown: counters.portal_cooldown
                  }
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

    {local, state} = portal_contacts(state, local)

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
          do:
            Map.put(
              cache,
              step.id,
              {state.items.entries[step.id].physical_revision,
               resting_fence(state, step.position)}
            ),
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

  # Items in portals (VMC-026c): local steps meeting a portal renew their
  # cooldown; one off cooldown starts this owner's single destination job.
  defp portal_contacts(state, local) do
    read = fn cells ->
      Blocks.get_many(state.blocks, Enum.filter(cells, &in_region?(state, &1)))
    end

    case ItemPortals.contacts(local, state.items.entries, read, state.item_portal == nil) do
      {local, nil} ->
        {local, state}

      {local, {step, _, _} = travel} ->
        case ItemPortals.start(self(), state.items.epoch, travel) do
          {:ok, job} ->
            local = Enum.map(local, &if(&1.id == step.id, do: ItemPortals.renew(&1), else: &1))
            {local, %{state | item_portal: job}}

          {:error, _} ->
            {local, state}
        end
    end
  end

  # A travelled item moves once this owner's item plans and outgoing intent are free.
  defp travel_item(%{item_portal: %{target: nil} = job} = state) do
    if ItemPortals.expired?(job) do
      Process.demonitor(job.monitor, [:flush])
      Process.exit(job.worker, :kill)
      %{state | item_portal: nil}
    else
      state
    end
  end

  defp travel_item(%{item_portal: %{target: target, uuid: uuid}} = state)
       when state.item_pending == nil and state.items.ledger.outgoing == nil and
              state.item_storage_enabled do
    state = %{state | item_portal: nil}
    deadline = System.monotonic_time(:millisecond) + 250

    case ItemPortals.arrival(state.items, state.key, uuid, target) do
      :gone ->
        state

      {:local, step} ->
        {:reply, _, next} =
          handle_call({:publish_item_motion, state.items.epoch, [step], deadline}, nil, state)

        next

      {:handoff, destination, step} ->
        case plan_item_change(:item_handoff_out, {destination, [step], deadline}, nil, state) do
          {:noreply, next} -> next
          {:reply, _, next} -> next
        end
    end
  end

  defp travel_item(state), do: state

  defp rests?(%{velocity: {x, y, z}, on_ground: ground, no_gravity: floating}),
    do: (ground or floating) and y == 0.0 and x * x + z * z <= 1.0e-10

  # A handoff leaves only once its outgoing ledger record is durable: callers
  # reach this through `resume_handoff/1`, except at load.
  defp resume_handoff(state), do: {:effect, {:resume_item_handoff, state.items.ledger.outgoing}}

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

    wait_durable(state, [resume_handoff(state)])
  end

  @doc """
  After a tick at game tick `tick` (VMC-077e): expire timed tickets, and
  `{:unload, state}` once the owner has had no ticket and no work in flight for
  `region_unload_delay_ms` (`{:ok, state}` until then). A world without a path
  keeps its regions, having nowhere to save them, and so does `/save-off`, as
  vanilla's `noSave` keeps its chunks.
  """
  def lifecycle(state, tick, now) do
    state = %{state | tickets: Tickets.expire(state.tickets, tick)}

    cond do
      not Tickets.empty?(state.tickets) or busy?(state) ->
        {:ok, %{state | idle_since: nil}}

      state.idle_since == nil ->
        {:ok, %{state | idle_since: now}}

      now - state.idle_since >= Valimc.config(:region_unload_delay_ms, state.key) and
        Valimc.config(:world_path, state.key) != nil and Valimc.World.Saving.auto?() ->
        {:unload, state}

      true ->
        {:ok, state}
    end
  end

  # Work that an unload would cut short: queued or planned writes, jobs, an
  # outbox still being delivered, generation, waiting calls, open containers and
  # granted permits.
  defp busy?(state) do
    gen = state.generation

    RegionStorage.busy?(state.storage) or state.item_pending != nil or
      state.item_handoff != nil or state.item_simulation != nil or state.item_portal != nil or
      state.item_cross_job != nil or state.cooking.job != nil or
      state.cooking_orbs.job != nil or state.cooking_orbs.delivery != nil or
      state.cooking_orbs.receipt != nil or map_size(state.jobs) > 0 or
      map_size(gen.jobs) > 0 or gen.deferred_count > 0 or
      map_size(state.container_viewers.views) > 0 or map_size(state.permits.entries) > 0
  end

  def terminate(reason, state) do
    CookingOrbRuntime.terminate(state.cooking_orbs)
    CookingOrbDelivery.terminate(state.cooking_orbs)

    if state.cooking.job do
      Process.cancel_timer(state.cooking.job.timer)
      Process.exit(state.cooking.job.worker, :kill)
    end

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

    # A clean stop (unload, shutdown) cuts the last frame, waits for it and
    # leaves a checkpoint, so nothing of the region stays in the log. Replies
    # still waiting on a frame (a failed one, or any after a crash) learn its
    # outcome is uncertain; a retry or the transfer's recovery resolves it.
    state =
      if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
        do: save_now(state),
        else: state

    for {:reply, from, _} <-
          state.storage.waits ++ Enum.flat_map(Map.values(state.storage.in_flight), & &1),
        not match?({:deliver, _}, from),
        do: reply_item(from, {:error, :item_commit_uncertain})

    :ok
  end
end
