defmodule Valimc.World.RegionData do
  @moduledoc "One storage resource's data and operations, executed by its owning process."
  alias Valimc.Data.Grid

  alias Valimc.World.{
    BlockBodies,
    BlockEntities,
    Clock,
    Explosion,
    LootChests,
    ScheduledTicks,
    TickBehaviours,
    BlockBatch,
    Blocks,
    BlockSnapshot,
    Chunk,
    CookingRuntime,
    ContainerViewers,
    ContainerClicks,
    ContainerLifecycle,
    Jobs,
    RegionEntities,
    EntityHandoffDelivery,
    EntityPortals,
    ItemCrossMergeQuery,
    RegionGeneration,
    RegionStorage,
    Tickets
  }

  alias Valimc.Worldgen.Generator

  alias Valimc.Entity.{Body, Publication, Store, ExperienceOrbs, Handoffs, Tracking, ItemMerges}
  alias Valimc.Entity.{EffectCloud, Projectile}
  alias Valimc.World.Projectiles
  alias Valimc.World.ContainerSpills

  alias Valimc.Data.Error
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.Packets
  alias Valimc.Txn.Permits
  alias Valimc.World.BlockRules
  alias Valimc.Blocks.Redstone
  import Bitwise, only: [|||: 2]

  @lava_states Valimc.Data.Blocks.states("lava") |> Enum.to_list()

  defstruct [
    # The section's dimension and coordinates `{sx, sz}`; its routing key is
    # `{dimension, sx, sz}` (`route_key/1`, VMC-077j).
    :dimension,
    :key,
    # The owner's incarnation: handles and messages of an older one are stale.
    :epoch,
    # What readers see without asking: chunk rows, packets, entity views.
    :publication,
    :block_entities,
    :containers,
    :container_viewers,
    :cooking_progress,
    :cooking,
    # Store and the item work the owner schedules (`RegionEntities`).
    :entities,
    :permits,
    :blocks,
    :cache,
    # Chunk packet encodes in flight, by chunk.
    :encodes,
    # Background work: one job per kind (`Valimc.World.Jobs`, VMC-077g).
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
    :scheduled_ticks,
    :tick_index,
    :rule_backlog,
    # Generated chunks' post-processing (VMC-031a): `chunk => {marks, fluid
    # ticks}`, settled when the chunk first ticks with its neighbours present.
    {:post, %{}},
    # Generated chunks' kept starts of structures that override spawns
    # (VMC-042b): `chunk => [{structure, box, pieces}]`, which natural
    # spawning reads.
    {:structures, %{}},
    # The group's other sections (VMC-077j), as the group hands them in
    # (`Region`): what the block rules read across and whether a plan holds
    # each; and what this section's call did to them (block-rule changes,
    # entities moved there), which the group applies once the call returns.
    {:siblings, %{}},
    {:sibling_effects, []},
    # The players standing in the section, as their group's trackers last
    # published them (`Valimc.Player.Host.track/1`): their rows, and the
    # packets not yet in a frame.
    {:player_views, %{}},
    {:player_frame, %{}},
    # The playing players of the group the orbs follow: `{feet, aim}`; and
    # what mobs' AI senses of them (`Player.Host.sensed/1`, VMC-041a).
    {:player_targets, []},
    # The same players as projectiles hit them (VMC-037o): `%{uuid, id,
    # position, box}`.
    {:player_bodies, []},
    {:player_sensed, []},
    # The level random mobs' brains draw on (VMC-041a2), the section's own.
    {:ai_random, nil},
    # Explosions whose craters wait for the crater job (VMC-050a):
    # `[{explosion, cells}]`, at most 64.
    {:explosions, []},
    # Redstone torches' recent toggles (VMC-047a, `RECENT_TOGGLES`, which
    # vanilla keeps per level in memory): `[{position, game tick}]`.
    {:torch_toggles, []},
    # Comparators' outputs (VMC-048a, their block entities'): `position =>
    # output`, persisted; the block rules keep it.
    {:comparators, %{}},
    # The containers as comparators last heard of them: a change of a
    # container's signal reaches them at the next block phase.
    :containers_seen,
    :random_tick_speed,
    # Durability: keyed change records on the shared log (VMC-077f).
    :storage
  ]

  # A generated world's region loads without generating: chunks its log has no
  # column for are absent until they are wanted and generated (VMC-075,
  # `RegionGeneration`).
  def load(dimension, key) do
    {storage, loaded} =
      case RegionStorage.open(dimension, key) do
        {:ok, storage, loaded} -> {storage, loaded}
        {:error, reason} -> exit({:shutdown, {:region_storage_unavailable, reason}})
      end

    images = loaded.columns
    generation = RegionGeneration.new(dimension, key, images)

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
      case Store.restore(key, loaded.items, loaded.ledger) do
        {:ok, items} -> items
        {:error, reason} -> exit({:item_load_failed, reason})
      end

    tick_index = TickBehaviours.index(TickBehaviours.modules(key))

    # The native sampler returns only states some behaviour handles randomly.
    :ok =
      Blocks.random_ticking(
        blocks,
        for({state, module} <- tick_index, function_exported?(module, :random_tick, 4), do: state) ++
          Enum.to_list(Valimc.Data.Blocks.states("lava")) ++ Valimc.World.Growth.states()
      )

    publication = :ets.new(:region_publication, [:set, :protected, read_concurrency: true])
    # Every generated chunk has a row, with its heightmaps and biomes (VMC-077e).
    present =
      for chunk <- RegionGeneration.chunks_of(key),
          not RegionGeneration.absent?(generation, chunk),
          do: chunk

    :ok = BlockSnapshot.publish_chunks(publication, blocks, present, 0)
    :ok = BlockSnapshot.publish_absent(publication, MapSet.to_list(generation.absent))

    %__MODULE__{
      dimension: dimension,
      key: key,
      epoch: items.epoch,
      publication: publication,
      entities: %RegionEntities{
        store: items,
        tracking: %Tracking{tick: loaded.game_tick},
        persistent: loaded.persistent,
        simulate: Valimc.config(:item_simulation, key)
      },
      containers: loaded.containers,
      containers_seen: loaded.containers,
      comparators: loaded.comparators,
      block_entities: block_entities,
      container_viewers: %ContainerViewers{},
      cooking_progress: %{},
      cooking: %CookingRuntime{enabled: Valimc.config(:cooking_simulation, key)},
      permits: Valimc.Txn.Permits.new(),
      blocks: blocks,
      cache: %{},
      encodes: %{},
      jobs: %Jobs{},
      versions: %{},
      served: MapSet.new(),
      generation: generation,
      tickets: Tickets.new(0),
      idle_since: nil,
      revision: 0,
      section_revisions: %{},
      game_tick: loaded.game_tick,
      scheduled_ticks: loaded.ticks,
      tick_index: tick_index,
      rule_backlog: [],
      post: loaded.post_processing,
      structures: loaded.structures,
      random_tick_speed: Valimc.config(:random_tick_speed, key),
      storage: storage
    }
    |> publish_item_views()
    |> baseline_storage()
    |> resume_item_handoff()
  end

  @doc "The section's routing key `{dimension, sx, sz}`."
  def route_key(%{dimension: dimension, key: {sx, sz}}), do: {dimension, sx, sz}

  @doc "The owner's keyed parts that `RegionStorage` diffs into frames and checkpoints."
  def parts(state),
    do: %{
      items: state.entities.store,
      containers: state.containers,
      ticks: state.scheduled_ticks,
      block_entities: state.block_entities,
      comparators: state.comparators,
      post: state.post,
      structures: state.structures,
      game_tick: state.game_tick
    }

  defp baseline_storage(state),
    do: %{state | storage: RegionStorage.baseline(state.storage, parts(state))}

  def item_tick(state, now) do
    state = travel_item(state)

    state =
      if state.entities.dropped != [] and not planning?(state),
        do:
          adopt_drops(
            %{state | entities: %{state.entities | dropped: []}},
            state.entities.dropped
          ),
        else: state

    state =
      if Tickets.simulating?(state.tickets),
        do: state |> simulate_items(now) |> redstone_contacts(),
        else: state

    track_entities(state)
  end

  defp simulate_items(state, now) do
    # A planning worker's result replaces the item map, so ageing waits while one
    # runs; the skipped ticks are owed and applied at once, so despawn timing
    # never stalls.
    ticks = state.entities.age_debt + 1

    {items, expired} =
      if state.entities.simulate and not planning?(state),
        do: Store.age(state.entities.store, ticks),
        else: {nil, []}

    if items != nil and (expired == [] or write_busy(state) == nil) do
      state = remember_item_counters(%{state | entities: %{state.entities | age_debt: 0}}, items)

      if expired == [] do
        state
        |> tick_block_bodies()
        |> tick_projectiles()
        |> start_item_cross_merging(now)
        |> move_mobs()
        |> move_items(now)
      else
        items =
          Enum.reduce(expired, items, fn {epoch, id, revision}, acc ->
            {:ok, next} = Store.remove(acc, epoch, id, revision)
            next
          end)

        {:noreply, state} = commit_items(items, :ok, nil, state)
        state
      end
    else
      if state.entities.simulate,
        do: %{state | entities: %{state.entities | age_debt: min(ticks, 6000)}},
        else: state
    end
  end

  def cooking_tick(%{cooking: runtime} = state, now) do
    cond do
      not runtime.enabled or not state.entities.persistent or
        Jobs.running?(state.jobs, :cooking) or write_busy(state) != nil ->
        state

      is_integer(runtime.retry_at) and now < runtime.retry_at and runtime.seen == nil ->
        state

      CookingRuntime.due?(runtime, state.containers, state.revision, state.entities.store, now) ->
        start_cooking_plan(state, now)

      true ->
        state
    end
  end

  defp start_cooking_plan(state, now) do
    containers = state.containers
    items = state.entities.store
    # Workers get values: the blocks under every cooking container, not the storage handle.
    edits = Blocks.get_many(state.blocks, for({p, %{cooking: _}} <- containers.entries, do: p))
    key = state.key
    selection = CookingRuntime.selection(state.cooking, containers, state.revision, items, now)
    blocked = state.cooking.blocked

    case start_job(
           state,
           :cooking,
           fn -> CookingRuntime.plan(containers, items, key, edits, selection, blocked) end,
           supervisor: Valimc.ItemWorkers,
           deadline: 500,
           data: %{containers: containers, items: items}
         ) do
      {:ok, state} ->
        Valimc.Data.Metrics.add(:cooking_batches)
        state

      {:error, _} ->
        Valimc.Data.Metrics.add(:cooking_busy)
        %{state | cooking: %{state.cooking | seen: nil, retry_at: now + 100}}
    end
  end

  @doc false
  # Start background work `kind` on the job table; its reports carry the epoch.
  def start_job(state, kind, work, opts) do
    epoch = state.epoch
    section = route_key(state)
    owner = self()

    # The report goes to the section's group when the work is done: the one
    # that started it may have handed the section on and retired (VMC-077y).
    reply_to = fn ->
      with {pid, _, _} <- Valimc.World.Directory.lookup(section), do: pid, else: (_ -> owner)
    end

    case Jobs.start(
           state.jobs,
           kind,
           work,
           [wrap: &{:resource, epoch, &1}, reply_to: reply_to] ++ opts
         ) do
      {:ok, jobs, _job} -> {:ok, %{state | jobs: jobs}}
      {:error, _} = error -> error
    end
  end

  defp accept_cooking_plan(state, job, plan) do
    current =
      not planning?(state) and state.containers == job.containers and
        Enum.all?(plan.expected, fn {position, block} ->
          Blocks.get(state.blocks, position) == block
        end)

    with true <- current,
         {:ok, items} <- Store.merge_created(state.entities.store, job.items, plan.items) do
      plan = %{plan | items: items}

      if plan.changes == %{},
        do: finish_cooking(state, plan),
        else: commit_cooking(state, plan)
    else
      _ ->
        Valimc.Data.Metrics.add(:cooking_stale)
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
        Valimc.Data.Metrics.add(:cooking_commits)

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
        Valimc.Data.Metrics.add(:cooking_plan_failures)

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

    state = publish_item_views(%{state | entities: %{state.entities | store: plan.items}})

    state = %{
      state
      | containers: plan.containers,
        cooking: runtime,
        cooking_progress: Map.take(state.cooking_progress, Map.keys(plan.containers.entries)),
        permits:
          Valimc.Txn.Permits.invalidate(state.permits, Map.new(plan.content, &{&1, nil}), [
            :mining,
            :placement
          ]),
        entities: %{state.entities | store: plan.items}
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
               {:container_progress, {self(), state.epoch}, ref, position, progress}}

      %{
        state
        | container_viewers: viewers,
          cooking_progress: Map.put(state.cooking_progress, position, generation)
      }
      |> release_now(deliveries)
    end)
  end

  # A border item that can merge into a neighbour's is handed over to merge
  # there (VMC-077h); the neighbour decides, and a rejected donor comes back.
  defp start_item_cross_merging(state, now) do
    entities = state.entities

    if entities.persistent and entities.store.ledger.outgoing == nil and not planning?(state) and
         (entities.cross_next == nil or now >= entities.cross_next) do
      state = %{state | entities: %{entities | cross_next: now + 200}}

      case ItemCrossMergeQuery.scene(state.dimension, state.key, entities.store.views) do
        nil ->
          %{state | entities: %{state.entities | cross_stamp: nil}}

        %{stamp: stamp} when stamp == entities.cross_stamp ->
          state

        scene ->
          with {id, destination, target} <- ItemCrossMergeQuery.pick(route_key(state), scene),
               %{revision: revision} <- entities.store.entries[id] do
            request = {{id, revision}, destination, target, now + 250}

            if local_destination?(state, destination) do
              merge_into_sibling(state, destination, {id, revision}, target)
            else
              case plan_item_change(:item_merge_out, request, nil, state) do
                {:noreply, next} ->
                  Valimc.Data.Metrics.add(:item_cross_merges)
                  next

                {:reply, _, next} ->
                  next
              end
            end
          else
            _ -> %{state | entities: %{state.entities | cross_stamp: scene.stamp}}
          end
      end
    else
      state
    end
  end

  defp start_item_merging(state, now) do
    # Only items merge: other kinds neither start nor restart a merge plan.
    items = for {id, %{kind: :item} = entry} <- state.entities.store.entries, do: {id, entry}

    if state.entities.persistent and length(items) >= 2 and
         (state.entities.merge_next == nil or now >= state.entities.merge_next) do
      stamp = Map.new(items, fn {id, entry} -> {id, entry.physical_revision} end)

      state = %{state | entities: %{state.entities | merge_next: now + 200}}

      if stamp == state.entities.merge_stamp do
        state
      else
        case plan_item_change(:item_merge_auto, {nil, now + 250}, nil, state) do
          {:noreply, next} ->
            Valimc.Data.Metrics.add(:item_merge_jobs)
            %{next | entities: %{next.entities | merge_stamp: stamp}}

          {:reply, _, next} ->
            Valimc.Data.Metrics.add(:item_merge_busy)
            next
        end
      end
    else
      state
    end
  end

  # Primed TNT (VMC-050a): its motion and fuse each tick, through the physics
  # kernel like items, and its explosion once the fuse runs out. Bodies move
  # while no write is in flight; a crater waiting for its job starts here.
  defp tick_block_bodies(state) do
    bodies =
      for {id, %{kind: :object, body: %{type: type}, entity: %{x: x, z: z}} = entry} <-
            state.entities.store.entries,
          BlockBodies.ticks?(type),
          Tickets.simulated?(state.tickets, Grid.chunk_key(x, z)),
          do: {id, entry}

    state =
      if bodies == [] or write_busy(state) != nil,
        do: state,
        else:
          step_block_bodies(
            state,
            BlockBodies.tick(bodies, Clock.border_snapshot(), &read_block(state, &1))
          )

    start_craters(state)
  end

  defp step_block_bodies(state, steps) do
    route = route_key(state)

    start = %{
      store: state.entities.store,
      moves: [],
      explosions: [],
      edits: %{},
      records: [],
      events: [],
      hurts: []
    }

    acc = Enum.reduce(steps, start, &block_body_step(&1, &2, state.dimension, route, state.key))
    state = put_entities(state, acc.store)

    # A body that crossed into a sibling section goes there in this commit;
    # one bound for another group stays (groups keep loaded chunks apart).
    state =
      Enum.reduce(Enum.reverse(acc.moves), state, fn {destination, step}, next ->
        if local_destination?(next, destination),
          do: move_to_sibling(next, destination, [step]),
          else: next
      end)

    state =
      state
      |> commit_landings(acc.edits, Enum.reverse(acc.records))
      |> rule_events(Enum.reverse(acc.events))

    state = Enum.reduce(Enum.reverse(acc.hurts), state, &falling_hit(&2, &1))
    Enum.reduce(Enum.reverse(acc.explosions), state, &explode(&2, &1))
  end

  defp block_body_step(
         {:moved, id, revision, {x, _, z} = position, body},
         acc,
         dimension,
         route,
         key
       ) do
    destination = Grid.section(dimension, Grid.chunk_key(x, z))
    %{x: ox, y: oy, z: oz} = acc.store.entries[id].entity
    here = if destination == route, do: position, else: {ox, oy, oz}

    case Store.step_body(acc.store, key, id, revision, here, body) do
      {:ok, next, {_, _, next_revision}} when destination != route ->
        move = {destination, %{id: id, revision: next_revision, position: position}}
        %{acc | store: next, moves: [move | acc.moves]}

      {:ok, next, _} ->
        %{acc | store: next}

      _ ->
        acc
    end
  end

  defp block_body_step({:hurt, box, amount}, acc, _, _, _),
    do: %{acc | hurts: [{box, amount} | acc.hurts]}

  defp block_body_step(step, acc, _, _, _) do
    {id, revision} = {elem(step, 1), elem(step, 2)}

    case Store.remove(acc.store, acc.store.epoch, id, revision) do
      {:ok, store} -> gone(step, %{acc | store: store})
      _ -> acc
    end
  end

  defp gone({:explode, _, _, position}, acc),
    do: %{acc | explosions: [Explosion.tnt(position) | acc.explosions]}

  defp gone({:land, _, _, cell, block, events}, acc),
    do: %{
      acc
      | edits: Map.put(acc.edits, cell, block),
        events: level_events(cell, events) ++ acc.events
    }

  defp gone({:drop, _, _, {x, y, z}, block, events}, acc) do
    stack =
      Valimc.Protocol.ItemStack.new(Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(block)))

    [vx, vz] = for _ <- 1..2, do: :rand.uniform_real() * 0.2 - 0.1

    # `spawnAtLocation`: at the body, launched as a new item entity is.
    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x,
      y: y,
      z: z,
      stack: stack,
      motion: %Valimc.Entity.ItemMotionState{velocity: {vx, 0.2, vz}, pickup_delay: 10}
    }

    cell = {floor(x), floor(y), floor(z)}
    %{acc | records: [record | acc.records], events: level_events(cell, events) ++ acc.events}
  end

  defp gone({:discard, _, _, {x, y, z}, events}, acc),
    do: %{acc | events: level_events({floor(x), floor(y), floor(z)}, events) ++ acc.events}

  defp level_events(cell, events), do: Enum.reverse(for(event <- events, do: {cell, event, 0}))

  # Landed falling blocks place in this section's next frame with their
  # updates (`setBlockAndUpdate`); dropped ones' items join the store.
  defp commit_landings(state, edits, records) do
    state =
      with true <- map_size(edits) > 0,
           {:ok, batch} <- BlockBatch.prepare(edits),
           {:ok, proposal} <- block_proposal(state, batch) do
        publish_blocks(state, batch, proposal)
      else
        _ -> state
      end

    cond do
      records == [] ->
        state

      planning?(state) ->
        %{state | entities: %{state.entities | dropped: state.entities.dropped ++ records}}

      true ->
        adopt_drops(state, records)
    end
  end

  # Projectiles and area effect clouds (VMC-037o, `World.Projectiles`): one
  # kernel call moves the section's projectiles; each step's hit goes through
  # the hurt path (this section's mobs at once, the group's players by their
  # sessions) and its effects apply here; they travel as mobs do.
  defp tick_projectiles(state) do
    {projectiles, clouds} =
      for {id, %{kind: :object, body: %Body{type: type}, entity: %{x: x, z: z}} = entry} <-
            state.entities.store.entries,
          Projectile.projectile?(type) or type == EffectCloud.type(),
          Tickets.simulated?(state.tickets, Grid.chunk_key(x, z)),
          reduce: {[], []} do
        {p, c} ->
          if type == EffectCloud.type(), do: {p, [{id, entry} | c]}, else: {[{id, entry} | p], c}
      end

    if (projectiles == [] and clouds == []) or write_busy(state) != nil do
      state
    else
      targets = projectile_targets(state)
      state = Enum.reduce(Enum.sort(clouds), state, &tick_cloud(&2, &1, targets))

      steps =
        Projectiles.step(
          Enum.sort(projectiles),
          targets,
          Clock.border_snapshot(),
          state.dimension == :the_nether
        )

      context = %{mob_griefing: Valimc.World.GameRules.get(:mob_griefing)}
      by_id = Map.new(targets, &{&1.id, &1})

      {state, moves} =
        Enum.reduce(steps, {state, []}, fn {id, entry, result}, {acc, moves} ->
          run_projectile(acc, id, entry, Projectiles.plan(entry, result, by_id, context), moves)
        end)

      route_bodies(state, Enum.reverse(moves))
    end
  end

  # What projectiles may hit: this section's living mobs and the group's
  # players, `%{id, ref, uuid, type, position, box}`.
  defp projectile_targets(state) do
    mobs =
      for {sid, %{kind: :mob, body: %Body{type: type} = body, entity: e}} <-
            state.entities.store.entries,
          Body.alive?(body) do
        %{width: w, height: h} = Valimc.Data.EntityTypes.fetch(type)
        {x, y, z} = {e.x * 1.0, e.y * 1.0, e.z * 1.0}

        %{
          id: e.entity_id,
          ref: {:mob, sid},
          uuid: e.uuid,
          type: type,
          position: {x, y, z},
          box: {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}
        }
      end

    players =
      for p <- state.player_bodies,
          do: Map.merge(p, %{ref: {:player, p.uuid}, type: "minecraft:player"})

    mobs ++ players
  end

  defp run_projectile(state, id, entry, {:keep, body, position, effects}, moves) do
    state = Enum.reduce(effects, state, &projectile_effect(&2, entry, &1))
    {state, [%{id: id, revision: entry.revision, position: position, body: body} | moves]}
  end

  defp run_projectile(state, id, entry, {:remove, effects}, moves) do
    state = Enum.reduce(effects, state, &projectile_effect(&2, entry, &1))

    case Store.remove(state.entities.store, state.entities.store.epoch, id, entry.revision) do
      {:ok, store} -> {put_entities(state, store), moves}
      _ -> {state, moves}
    end
  end

  defp run_projectile(state, id, entry, {:hurt, target, hit, next}, moves) do
    {hurt, state} = projectile_hurt(state, target, hit)
    run_projectile(state, id, entry, next.(hurt), moves)
  end

  # A projectile's hit through the one hurt path: a mob of this section at
  # once (and set on fire when the hit says so), a player by its session,
  # whose hit is taken to land.
  defp projectile_hurt(state, %{ref: {:mob, sid}}, hit) do
    store = state.entities.store

    case Valimc.Entity.Combat.hurt(store, sid, hit) do
      {:ok, store, %{hurt: true}} ->
        store =
          case {hit[:ignite], store.entries[sid]} do
            {ticks, %{body: %Body{mob: mob} = body}} when is_integer(ticks) ->
              living = %{mob.living | fire_ticks: max(mob.living.fire_ticks, ticks)}
              Store.change_body(store, sid, %{body | mob: %{mob | living: living}})

            _ ->
              store
          end

        {true, put_entities(state, store)}

      {:ok, store, _} ->
        {false, put_entities(state, store)}

      _ ->
        {false, state}
    end
  end

  defp projectile_hurt(state, %{ref: {:player, uuid}}, hit) do
    send(self(), {:player, uuid, {:hurt, hit}})
    {true, state}
  end

  defp projectile_effect(state, _entry, {:sound, name, source, position, volume, pitch}) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    packet = Valimc.Protocol.CombatPackets.sound(name, source, position, volume, pitch, seed)
    Valimc.World.publish(route_key(state), {:sound, position, 16.0 * max(volume, 1.0), packet})
    state
  end

  # An entity event before the projectile goes (a snowball's or egg's break).
  defp projectile_effect(state, entry, {:event, event, position}) do
    packet = Valimc.Protocol.EntityPackets.entity_event(entry.entity.entity_id, event)
    Valimc.World.publish(route_key(state), {:sound, position, 64.0, binary_packet(packet)})
    state
  end

  defp projectile_effect(state, _entry, {:level_event, cell, type, data}) do
    Valimc.World.publish(route_key(state), {:level_events, [{cell, type, data}]})
    state
  end

  defp projectile_effect(state, _entry, {kind, record}) when kind in [:spawn, :cloud],
    do: commit_landings(state, %{}, [record])

  defp projectile_effect(state, _entry, {:explode, explosion}), do: explode(state, explosion)

  # `SmallFireball.onHitBlock`: fire in the cell before the face it hit, if empty.
  defp projectile_effect(state, _entry, {:fire, {x, y, z} = cell}) do
    with state_id when is_integer(state_id) <- read_block(state, cell),
         true <- Valimc.Data.BlockFacts.air?(state_id),
         below when is_integer(below) <- read_block(state, {x, y - 1, z}) do
      commit_landings(state, %{cell => Explosion.fire_state(below)}, [])
    else
      _ -> state
    end
  end

  defp projectile_effect(state, _entry, {:player, uuid, message}) do
    send(self(), {:player, uuid, message})
    state
  end

  defp projectile_effect(state, entry, {:splash, body, location}) do
    living = projectile_targets(state)
    {hits, events} = Projectiles.splash(body, location, living, body.data.age)

    me = %{
      uuid: entry.entity.uuid,
      entity_id: entry.entity.entity_id,
      player: false,
      type: body.type,
      mainhand: nil
    }

    template = Projectiles.projectile_hit(body, me, location, :indirect_magic, 0.0)

    state =
      Enum.reduce(hits, state, fn
        {%{ref: {:player, uuid}}, actions}, acc ->
          send(self(), {:player, uuid, {:splash, actions, template}})
          acc

        {%{ref: {:mob, sid}} = target, actions}, acc ->
          Enum.reduce(actions, acc, &mob_effect(&2, sid, target, &1, template))
      end)

    Enum.reduce(events, state, &projectile_effect(&2, entry, &1))
  end

  # An effect a potion or cloud gives mob `sid`.
  defp mob_effect(state, _sid, target, {:hurt, type, amount}, template) do
    hit = %{template | source: Valimc.Living.DamageSource.new(type), amount: amount}
    elem(projectile_hurt(state, target, Map.delete(hit, :direction)), 1)
  end

  defp mob_effect(state, sid, _target, {:heal, amount}, _template) do
    update_mob(state, sid, fn mob ->
      {:ok, health} = Valimc.Living.Health.heal(mob.living.health, amount)
      %{mob | living: %{mob.living | health: health}}
    end)
  end

  defp mob_effect(state, sid, _target, {:add, id, rung}, _template) do
    update_mob(state, sid, fn mob ->
      case Valimc.Living.Effects.add(mob.living.effects, id, rung) do
        {:ok, effects, _} -> %{mob | living: %{mob.living | effects: effects}}
        _ -> mob
      end
    end)
  end

  defp update_mob(state, sid, fun) do
    store = state.entities.store

    case store.entries[sid] do
      %{body: %Body{mob: mob} = body} when mob != nil ->
        put_entities(state, Store.change_body(store, sid, %{body | mob: fun.(mob)}))

      _ ->
        state
    end
  end

  # One tick of an area effect cloud over the section's living targets.
  defp tick_cloud(state, {id, %{entity: e, body: body, revision: revision}}, targets) do
    position = {e.x, e.y, e.z}
    store = state.entities.store

    case EffectCloud.tick(body, position, targets) do
      :remove ->
        case Store.remove(store, store.epoch, id, revision) do
          {:ok, store} -> put_entities(state, store)
          _ -> state
        end

      {:keep, next, effects} ->
        state =
          case Store.step_body(store, state.key, id, revision, position, next) do
            {:ok, store, _} -> put_entities(state, store)
            _ -> state
          end

        me = %{
          uuid: e.uuid,
          entity_id: e.entity_id,
          player: false,
          type: body.type,
          mainhand: nil
        }

        owner = body.data.owner

        attacker =
          if owner,
            do: %{
              uuid: owner.uuid,
              entity_id: owner.id,
              player: owner.player,
              type: nil,
              mainhand: nil
            },
            else: me

        template = %{
          source: Valimc.Living.DamageSource.new(:indirect_magic),
          amount: 0.0,
          attacker: attacker,
          direct: me,
          position: position
        }

        Enum.reduce(effects, state, fn
          {:hurt, %{ref: {:player, uuid}}, amount}, acc ->
            send(self(), {:player, uuid, {:hurt, %{template | amount: amount}}})
            acc

          {:hurt, %{ref: {:mob, sid}} = target, amount}, acc ->
            mob_effect(acc, sid, target, {:hurt, :indirect_magic, amount}, template)

          {:heal, %{ref: {:player, uuid}}, amount}, acc ->
            send(self(), {:player, uuid, {:splash, [{:heal, amount}], template}})
            acc

          {:heal, %{ref: {:mob, sid}} = target, amount}, acc ->
            mob_effect(acc, sid, target, {:heal, amount}, template)
        end)
    end
  end

  defp binary_packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  # An anvil landing on living entities (VMC-050a2): this section's mobs in
  # its box, and the group's players by their sessions.
  defp falling_hit(state, {box, amount}) do
    store =
      Enum.reduce(state.entities.store.entries, state.entities.store, fn
        {id, %{kind: :mob, body: body} = entry}, acc ->
          if Explosion.box_hit?(entry, box) do
            {hurt, events} = Body.hurt(body, :falling_anvil, amount)
            Store.change_body(acc, id, hurt, events)
          else
            acc
          end

        _, acc ->
          acc
      end)

    effect = {:players, {:falling_block, box, amount}}
    %{put_entities(state, store) | sibling_effects: state.sibling_effects ++ [effect]}
  end

  # An explosion (VMC-050a, `Valimc.World.Explosion`): its reach as the rows
  # stand, this section's entities hit now, its siblings' with this call and
  # the group's players by their sessions, and its crater by the crater job.
  defp explode(state, explosion) do
    case Explosion.reach(explosion) do
      {:ok, cells} ->
        store = state.entities.store
        hits = Explosion.hits(explosion, store.entries)
        state = put_entities(state, Explosion.apply_hits(store, state.key, hits))

        siblings =
          for key <- Explosion.sections(explosion),
              key != state.key and Map.has_key?(state.siblings, key),
              do: {key, {:explosion, explosion}}

        effects = siblings ++ [{:players, {:explosion, explosion, length(cells)}}]

        %{state | sibling_effects: state.sibling_effects ++ effects}
        |> queue_crater(explosion, cells)

      error ->
        require Logger
        Logger.warning("Explosion at #{inspect(explosion.center)} failed: #{inspect(error)}")
        state
    end
  end

  # Craters wait for the one crater job; past 64 the newest two merge.
  defp queue_crater(state, explosion, cells) do
    pending = state.explosions ++ [{explosion, cells}]

    pending =
      if length(pending) > 64 do
        {kept, [{_, a}, {last, b}]} = Enum.split(pending, -2)
        kept ++ [{last, Map.to_list(Map.merge(Map.new(a), Map.new(b)))}]
      else
        pending
      end

    start_craters(%{state | explosions: pending})
  end

  defp start_craters(%{explosions: []} = state), do: state

  defp start_craters(state) do
    if Jobs.running?(state.jobs, :explosion) do
      state
    else
      case start_job(state, :explosion, Explosion.work(state.dimension, state.explosions),
             supervisor: Valimc.TransferWorkers,
             deadline: 15_000
           ) do
        {:ok, state} -> %{state | explosions: []}
        {:error, _} -> state
      end
    end
  end

  defp remember_item_counters(state, items) do
    if items == state.entities.store do
      state
    else
      %{state | entities: %{state.entities | store: items}}
    end
  end

  # Store move in the items phase, all at once through the physics kernel over
  # published rows (VMC-077l); publishing the steps then starts merging.
  defp move_items(state, now) do
    # Bodies (VMC-043a) are inert until VMC-015i moves them.
    {items, orbs} =
      state.entities.store.entries
      |> Enum.filter(fn {_, %{kind: kind, entity: %{x: x, z: z}}} ->
        kind in [:item, :orb] and Tickets.simulated?(state.tickets, Grid.chunk_key(x, z))
      end)
      |> Enum.split_with(fn {_, entry} -> entry.kind == :item end)

    # Fire cannot hurt some stacks (netherite, VMC-034n4d).
    inputs =
      Enum.map(items, fn {id, entry} ->
        step_input(id, entry)
        |> Map.put(:fire_immune, Valimc.Living.Armor.resists_fire?(entry.stack))
      end)

    # An orb follows the nearest playing player within eight blocks
    # (`ExperienceOrb.followNearbyPlayer`), toward half its eye height.
    orbs =
      Enum.map(orbs, fn {id, entry} ->
        step_input(id, entry) |> Map.put(:target, follow(state.player_targets, entry.entity))
      end)

    if inputs == [] and orbs == [] do
      start_item_merging(state, now)
    else
      steps = Valimc.World.ItemStep.steps(inputs) ++ Valimc.World.ItemStep.orb_steps(orbs)
      {:noreply, state} = commit_simulated_items(state, steps)
      state
    end
  end

  # Mobs travel in the entity phase (VMC-015i): one kernel call for the
  # section's simulated mobs and their living rules; each step lands here, in
  # a sibling section in the same commit, or in another group by the handoff.
  defp move_mobs(state) do
    store = state.entities.store

    mobs =
      for {id, %{kind: :mob, entity: %{x: x, z: z}} = entry} <- store.entries,
          Tickets.simulated?(state.tickets, Grid.chunk_key(x, z)),
          do: {id, entry}

    if mobs == [] or write_busy(state) != nil do
      state
    else
      view = Valimc.World.View.new(state.dimension)
      world = mob_world(state, view)

      {steps, world} =
        Valimc.Entity.MobTicks.steps(
          view,
          Enum.sort(mobs),
          world,
          Valimc.World.Clock.border_snapshot()
        )

      state = %{state | ai_random: world.random}

      attacks =
        for step <- steps, {:attack, {:player, target}} <- step.effects, do: {step.id, target}

      # Items a mob picked up (a piglin's gold, VMC-041a2) and drops it let go.
      pickups =
        for step <- steps, {:pickup, {:item, uuid}, n} <- step.effects, do: {step.id, uuid, n}

      drops = for step <- steps, {:drop, stack} <- step.effects, do: {step.position, stack}

      # Mobs travel through portals (VMC-026d), standing in one too.
      {steps, state} = portal_contacts(state, steps)

      # Farmland mobs trampled (VMC-039a), while mob griefing is on.
      tramples =
        if Valimc.World.GameRules.get(:mob_griefing),
          do: for(step <- steps, {:trample, cell} <- step.effects, do: {:trample, cell}),
          else: []

      steps =
        Enum.reject(steps, fn step ->
          %{entity: e, body: body} = store.entries[step.id]
          step.events == [] and step.body == body and step.position == {e.x, e.y, e.z}
        end)

      state = route_bodies(state, steps)
      state = Enum.reduce(pickups, state, &mob_pickup/2)
      state = if drops == [], do: state, else: mob_drops(state, drops)
      state = if tramples == [], do: state, else: elem(rule_run(state, %{actions: tramples}), 0)

      # A mob's melee hit (VMC-041a) goes to the player's session here.
      for {id, target} <- attacks,
          %{entity: %{uuid: uuid}} <- [state.entities.store.entries[id]] do
        mob_attack(state, uuid, target)
      end

      state
    end
  end

  # `Mob.pickUpItem`'s `take`: `count` of item `uuid` leaves it for mob `id`
  # (the take animation goes to its viewers), the item gone when empty.
  defp mob_pickup({id, uuid, count}, state) do
    store = state.entities.store

    with {:ok, {epoch, item, revision}} <- Store.find(store, uuid),
         %{kind: :item, stack: stack} <- store.entries[item],
         remainder = if(stack.count > count, do: %{stack | count: stack.count - count}),
         {:ok, store} <- take(store, epoch, item, revision, remainder) do
      state = publish_item_views(%{state | entities: %{state.entities | store: store}})
      Valimc.World.publish(route_key(state), {:item_pickup, epoch, item, id, count})
      state
    else
      _ -> state
    end
  end

  # `spawnAtLocation`: stacks a mob lets go, where it stands.
  defp mob_drops(state, drops) do
    records =
      for {{x, y, z}, stack} <- drops do
        [vx, vz] = for _ <- 1..2, do: :rand.uniform_real()

        %{
          uuid: :crypto.strong_rand_bytes(16),
          x: x,
          y: y,
          z: z,
          stack: stack,
          motion: %Valimc.Entity.ItemMotionState{
            velocity: {vx * 0.2 - 0.1, 0.2, vz * 0.2 - 0.1},
            pickup_delay: 10
          }
        }
      end

    adopt_drops(state, records)
  end

  # What mobs' AI reads (`Valimc.AI.World`): this group's players, the
  # section's mobs (`AI.think/2` adds them) and items, published blocks,
  # game time, the section's level random.
  defp mob_world(state, view) do
    {min_y, height} = Valimc.World.Dimension.bounds(state.dimension)
    {difficulty, _} = Valimc.World.Clock.difficulty()

    items =
      for {_, %{kind: :item, entity: e, stack: stack} = entry} <- state.entities.store.entries,
          do: %{
            kind: :item,
            uuid: e.uuid,
            x: e.x * 1.0,
            y: e.y * 1.0,
            z: e.z * 1.0,
            width: 0.25,
            height: 0.25,
            eye: 0.2125000059604645,
            item: stack.item_id,
            count: stack.count,
            components: stack.components,
            pickup_delay: Map.get(entry, :motion, %{pickup_delay: 0}).pickup_delay,
            alive: true
          }

    %Valimc.AI.World{
      read: &Valimc.World.View.block(view, &1),
      find: &find_blocks(view, &1, &2),
      time: state.game_tick || 0,
      players: state.player_sensed,
      items: items,
      random: state.ai_random || Valimc.AI.Random.new(:rand.uniform(281_474_976_710_656)),
      difficulty: elem({:peaceful, :easy, :normal, :hard}, difficulty.level),
      min_y: min_y,
      max_y: min_y + height - 1
    }
  end

  defp find_blocks(view, {x0, y0, z0, x1, y1, z1}, states) do
    list = MapSet.to_list(states)

    for cx <- Integer.floor_div(x0, 16)..Integer.floor_div(x1, 16),
        cz <- Integer.floor_div(z0, 16)..Integer.floor_div(z1, 16),
        {{x, y, z}, state} <- Valimc.World.View.find(view, {cx, cz}, list),
        x in x0..x1 and y in y0..y1 and z in z0..z1,
        do: {{x, y, z}, state}
  end

  # Body steps by destination: this section, a sibling, or another group.
  defp route_bodies(state, []), do: state

  defp route_bodies(state, steps) do
    route = route_key(state)

    {local, borders} =
      Enum.split_with(steps, fn %{position: {x, _, z}} ->
        Grid.section(state.dimension, Grid.chunk_key(x, z)) == route
      end)

    state =
      Enum.reduce(Enum.chunk_every(local, 32), state, fn batch, acc ->
        case Store.advance(acc.entities.store, acc.key, acc.epoch, batch) do
          {:ok, store, _} -> %{acc | entities: %{acc.entities | store: store}}
          {:error, _} -> acc
        end
      end)

    {nearby, away} =
      borders
      |> Enum.group_by(fn %{position: {x, _, z}} ->
        Grid.section(state.dimension, Grid.chunk_key(x, z))
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.split_with(fn {destination, _} -> local_destination?(state, destination) end)

    state =
      for {destination, batch} <- nearby, chunk <- Enum.chunk_every(batch, 32), reduce: state do
        acc -> move_to_sibling(acc, destination, chunk)
      end

    if away != [] and state.entities.store.ledger.outgoing == nil and state.entities.persistent do
      [{destination, batch} | _] = away
      deadline = System.monotonic_time(:millisecond) + 250

      state
      |> then(
        &plan_item_change(
          :item_handoff_out,
          {destination, Enum.take(batch, 32), deadline},
          nil,
          &1
        )
      )
      |> elem(1)
    else
      state
    end
  end

  defp step_input(id, entry) do
    %{
      id: id,
      revision: entry.revision,
      position: {entry.entity.x, entry.entity.y, entry.entity.z},
      motion: entry.motion,
      physical_revision: entry.physical_revision
    }
  end

  defp follow(targets, %{x: x, y: y, z: z}) do
    targets
    |> Enum.map(fn {{px, py, pz}, aim} ->
      {(px - x) * (px - x) + (py - y) * (py - y) + (pz - z) * (pz - z), aim}
    end)
    |> Enum.filter(fn {distance, _} -> distance <= 64.0 end)
    |> Enum.min_by(&elem(&1, 0), fn -> {nil, nil} end)
    |> elem(1)
  end

  def handle_call({:create_item, epoch, stack, position}, from, state) do
    item_request(epoch, from, state, fn ->
      Store.create(state.entities.store, state.key, stack, position)
    end)
  end

  def handle_call({:replace_item, epoch, id, revision, stack}, from, state),
    do:
      item_request(epoch, from, state, fn ->
        Store.replace(state.entities.store, epoch, id, revision, stack)
      end)

  def handle_call({:remove_item, epoch, id, revision}, from, state),
    do:
      item_request(epoch, from, state, fn ->
        Store.remove(state.entities.store, epoch, id, revision)
      end)

  def handle_call({:menu, epoch, viewer, position, grant}, _from, state)
      when is_pid(viewer) do
    case redstone_use(state, epoch, viewer, position, grant) do
      {:used, state} ->
        {:reply, :used, state}

      :pass ->
        {decision, state} = menu_request(state, epoch, viewer, position, grant)
        {:reply, decision, state}
    end
  end

  # A click in a container menu (VMC-077i3), from the player's group: applied
  # to the container and `inventory` at once; an earned furnace output spawns
  # its orbs. The clicking view has seen the new revision; other viewers learn
  # of it. `{:ok, inventory, entry, learned}` or `{:error, reason}`.
  def handle_call({:container_click, epoch, viewer, ref, position, actor, click}, _from, state) do
    now = System.monotonic_time(:millisecond)
    block = if valid_block_query?([position], :any), do: Blocks.get(state.blocks, position)
    menu = Valimc.Menus.MenuAccess.menu(block)

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         true <- in_region?(state, position) or {:error, :wrong_region},
         nil <- write_busy(state),
         true <- menu in [:chest, :cooking] or {:error, :missing_container},
         :ok <- Valimc.Menus.MenuAccess.authorize_action(menu, block, position, actor, now),
         {:ok, containers, inventory, orbs, learned, drops} <-
           ContainerClicks.apply(
             state.containers,
             position,
             click.inventory,
             click,
             actor.position
           ) do
      state = %{state | containers: containers}
      state = if orbs == [], do: state, else: adopt_drops(state, orbs)
      entry = state.containers.entries[position]

      viewers =
        ContainerViewers.observed(state.container_viewers, viewer, ref, entry.revision)

      state = notify_container_changed(%{state | container_viewers: viewers}, position)
      entry = Map.put(entry, :generation, Map.get(state.cooking_progress, position, 0))
      {:reply, {:ok, inventory, entry, learned, drops}, state}
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # A survival player breaks the block at `position` it mined (VMC-077i3,
  # VMC-029e): each cell of `writes` is still its expected block and becomes
  # the new one (a container's contents spill), and the drops and orbs
  # `records` are adopted, in one plain call from its group.
  def handle_call({:mine_block, epoch, position, writes, records}, _from, state) do
    expected = Map.new(writes, fn {cell, {block, _}} -> {cell, block} end)
    cells = Map.keys(writes)

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         true <-
           (valid_block_query?(cells, :any) and Enum.all?(cells, &in_region?(state, &1))) or
             {:error, :wrong_region},
         nil <- write_busy(state),
         true <- Blocks.get_many(state.blocks, cells) == expected or {:error, :stale_block},
         # Breaking a chest drops its contents, which unpacks loot with no
         # player (luck 0), as `Containers.dropContents` does.
         state = unpack_to_break(state, position, expected[position]),
         {:ok, batch} <-
           BlockBatch.prepare(Map.new(writes, fn {cell, {_, new}} -> {cell, new} end)),
         {:ok, plan} <-
           block_container_metadata(
             %{expected: expected, batch: batch, items: state.entities.store},
             state.containers,
             state.key
           ),
         {:ok, proposal} <- block_proposal(state, batch, Map.get(plan, :removed, [])) do
      # The spill's store first: the break's block rules add the drops of the
      # blocks they destroy (a door's other half, a torch) to it.
      state = %{state | entities: %{state.entities | store: plan.items}}
      state = publish_blocks(state, batch, proposal)
      state = %{state | containers: Map.get(plan, :containers, state.containers)}
      state = publish_item_views(state)
      {:reply, :ok, adopt_drops(state, records)}
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # A player's item interactions (VMC-077i3) are plain calls from its group:
  # a drop adopts its records (after a running plan, whose result replaces the
  # store), a pickup takes what fits `inventory` of an item the player touches,
  # an XP pickup one unit of an orb. Each change is in the section's next frame.
  def handle_call({:drop_items, epoch, records}, _from, state) do
    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      planning?(state) ->
        entities = %{state.entities | dropped: state.entities.dropped ++ records}
        {:reply, :ok, %{state | entities: entities}}

      true ->
        {:reply, :ok, adopt_drops(state, records)}
    end
  end

  def handle_call({:take_item, epoch, actor, uuid, inventory}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {epoch, id, revision}} <- Store.find(store, uuid),
         %{kind: :item, stack: stack} = entry <- store.entries[id],
         true <- Valimc.Entity.ItemPickup.eligible?(actor, entry) or {:error, :not_eligible},
         {:ok, inventory, remainder, _} <- Inventory.pickup_stack(inventory, stack),
         true <- remainder != stack or {:error, :inventory_full},
         {:ok, items} <- take(store, epoch, id, revision, remainder) do
      taken = stack.count - if(remainder, do: remainder.count, else: 0)
      state = publish_item_views(%{state | entities: %{state.entities | store: items}})

      if remainder == nil,
        do:
          Valimc.World.publish(
            route_key(state),
            {:item_pickup, epoch, id, actor.entity_id, taken}
          )

      {:reply, {:ok, inventory, taken}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      _ -> {:reply, {:error, :pickup_not_available}, state}
    end
  end

  # `AbstractArrow.playerTouch` (VMC-037o): a stuck arrow whose shake is
  # over goes to the player that touches it as its pickup rule allows, with
  # the pickup animation.
  def handle_call({:take_arrow, epoch, actor, uuid, inventory}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {epoch, id, revision}} <- Store.find(store, uuid),
         %{body: %Body{type: "minecraft:arrow", data: %{in_ground: true, shake: 0}} = body} <-
           store.entries[id],
         {:ok, inventory} <- Valimc.Player.Projectiles.try_pickup(body, inventory),
         {:ok, store} <- Store.remove(store, epoch, id, revision) do
      state = put_entities(state, store)
      Valimc.World.publish(route_key(state), {:item_pickup, epoch, id, actor.entity_id, 1})
      {:reply, {:ok, inventory}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      _ -> {:reply, {:error, :pickup_not_available}, state}
    end
  end

  # A player's attack turns a fireball back (`ProjectileDeflection.AIM_DEFLECT`
  # by attack, VMC-037o): along the player's look, its acceleration reset.
  def handle_call({:deflect_projectile, epoch, uuid, look, owner}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{body: %Body{data: %{acceleration: _} = data} = body} <- store.entries[id] do
      body = %{body | velocity: look, data: %{data | owner: owner, acceleration: 0.1}}
      store = Store.change_body(store, id, Projectile.impulse(body))
      {:reply, :ok, put_entities(state, store)}
    else
      {:error, _} = error -> {:reply, error, state}
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      _ -> {:reply, {:error, :not_deflectable}, state}
    end
  end

  # `/kill` over this section's entities (VMC-043a): a mob starts dying, any
  # other entity is removed. The reply counts the entities killed.
  def handle_call({:kill_entities, epoch, uuids}, _from, state) do
    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state) do
      {store, killed} =
        Enum.reduce(uuids, {state.entities.store, 0}, fn uuid, {store, killed} ->
          with {:ok, {_, id, _}} <- Store.find(store, uuid),
               {:ok, next} <- Store.kill(store, id) do
            {next, killed + 1}
          else
            _ -> {store, killed}
          end
        end)

      {:reply, {:ok, killed}, put_entities(state, store)}
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # A hit on a body of this section (VMC-037n), as `hurt_entity/3`.
  def handle_call({:hurt_entity, epoch, uuid, hit}, _from, state) do
    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state) do
      {reply, state} = hurt_entity(state, uuid, hit)
      {:reply, reply, state}
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # A name tag on a living body (VMC-042a): named and persistent.
  def handle_call({:name_entity, epoch, uuid, name}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{kind: :mob, body: body} <- store.entries[id] || {:error, :missing_item},
         true <- Valimc.Entity.Body.alive?(body) or {:error, :not_alive} do
      {:reply, :ok,
       put_entities(state, Store.change_body(store, id, Valimc.Entity.Body.name(body, name)))}
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :not_living}, state}
    end
  end

  # A teleported entity (VMC-043a): it moves here, to a sibling section in
  # the same group commit, or to another group by the durable handoff.
  def handle_call({:move_entity, epoch, uuid, position, rotation}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, revision}} <- Store.find(store, uuid),
         true <- Store.valid_position?(position) or {:error, :invalid_item_position} do
      step = Store.teleport_step(store, id, revision, position, rotation)
      {x, _, z} = position
      destination = Grid.section(state.dimension, Grid.chunk_key(x, z))

      cond do
        destination == route_key(state) ->
          case Store.advance(store, state.key, store.epoch, [step]) do
            {:ok, next, _} -> {:reply, :ok, put_entities(state, next)}
            error -> {:reply, error, state}
          end

        local_destination?(state, destination) ->
          {:reply, :ok, move_to_sibling(state, destination, [step])}

        store.ledger.outgoing != nil or not state.entities.persistent ->
          {:reply, Error.retry(:item_handoff_busy), state}

        true ->
          deadline = System.monotonic_time(:millisecond) + 250

          case plan_item_change(:item_handoff_out, {destination, [step], deadline}, nil, state) do
            {:noreply, next} -> {:reply, :ok, next}
            {:reply, reply, next} -> {:reply, reply, next}
          end
      end
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  def handle_call({:take_orb, epoch, actor, uuid, value}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{kind: :orb, value: ^value, entity: %{x: x, y: y, z: z}} <- store.entries[id],
         true <- ExperienceOrbs.contact?(actor.box, {x, y, z}) or {:error, :not_eligible},
         {:ok, items, id} <- Store.take_orb(store, uuid, value) do
      state = publish_item_views(%{state | entities: %{state.entities | store: items}})

      Valimc.World.publish(
        route_key(state),
        {:experience_pickup, state.epoch, id, actor.entity_id}
      )

      {:reply, :ok, state}
    else
      {:error, _} = error -> {:reply, error, state}
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      _ -> {:reply, {:error, :pickup_not_available}, state}
    end
  end

  def handle_call({:merge_items, epoch, pairs, deadline}, from, state) do
    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      not state.entities.persistent ->
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
        do: Store.advance(state.entities.store, state.key, epoch, steps),
        else: {:error, :expired_item_step}
    end)
  end

  def handle_call({:publish_item_motion, epoch, steps, deadline}, _from, state) do
    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :expired_item_step}, state}

      true ->
        case Store.advance(state.entities.store, state.key, epoch, steps) do
          {:ok, items, handles} ->
            handles =
              Enum.map(handles, fn {epoch, id, revision} -> {self(), epoch, id, revision} end)

            if items == state.entities.store do
              {:reply, {:ok, handles}, state}
            else
              state = publish_item_views(%{state | entities: %{state.entities | store: items}})
              {:reply, {:ok, handles}, state}
            end

          error ->
            {:reply, error, state}
        end
    end
  end

  def handle_call({:handoff_items, epoch, destination, steps, deadline}, from, state) do
    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      not state.entities.persistent ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      state.entities.store.ledger.outgoing != nil ->
        {:reply, {:error, :item_handoff_busy}, state}

      not is_integer(deadline) or System.monotonic_time(:millisecond) >= deadline ->
        {:reply, {:error, :expired_item_step}, state}

      true ->
        plan_item_change(:item_handoff_out, {destination, steps, deadline}, from, state)
    end
  end

  def handle_call({:entity_handoff, epoch, transfer}, from, state) do
    cond do
      epoch != state.epoch -> {:reply, Error.retry(:stale_owner), state}
      not state.entities.persistent -> {:reply, {:error, :transfer_storage_disabled}, state}
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
      true -> plan_item_change(:item_handoff_in, transfer, from, state)
    end
  end

  def handle_call({:find_item, epoch, uuid}, _from, state) do
    result =
      if epoch == state.epoch,
        do: Store.find(state.entities.store, uuid),
        else: Error.retry(:stale_owner)

    reply =
      case result do
        {:ok, {epoch, id, revision}} -> {:ok, {self(), epoch, id, revision}}
        error -> error
      end

    {:reply, reply, state}
  end

  def handle_call({:chunk, key} = message, from, state) do
    cond do
      Grid.region_key(key) != state.key ->
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
      Enum.any?(chunks, &(Grid.region_key(&1) != state.key)) ->
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

        epoch != state.epoch ->
          Error.retry(:stale_owner)

        not fence_current?(state, expected_revision) ->
          {:error, :stale_revision}

        Enum.any?(positions, fn {x, _, z} ->
          Grid.region_key(Grid.chunk_key(x, z)) != state.key
        end) ->
          {:error, :wrong_region}

        absent_positions?(state, positions) ->
          Error.retry(:chunk_generating)

        true ->
          {:ok,
           %{
             owner: {self(), state.epoch},
             region: state.key,
             revision: state.revision,
             # The sections read: edits elsewhere in the region do not stale it.
             fence: fence(state, positions),
             blocks: Map.new(positions, &{&1, Blocks.get(state.blocks, &1)})
           }}
      end

    if result == Error.retry(:chunk_generating),
      do: {:reply, result, want_positions(state, positions)},
      else: {:reply, result, state}
  end

  # `/fillbiome` (VMC-053j4): the biome change applies at once and its column
  # images join the next frame like generated ones; viewers get `chunks_biomes`.
  def handle_call({:fill_biomes, epoch, chunks, box, biome, filter}, _from, state) do
    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      Enum.any?(chunks, fn chunk -> Grid.region_key(chunk) != state.key end) ->
        {:reply, {:error, :wrong_region}, state}

      absent_positions?(state, for({cx, cz} <- chunks, do: {cx * 16, 0, cz * 16})) ->
        {:reply, Error.retry(:chunk_generating), state}

      true ->
        case Blocks.fill_biomes(state.blocks, chunks, box, biome, filter) do
          {:ok, {count, []}} ->
            {:reply, {:ok, count}, state}

          {:ok, {count, images}} ->
            columns = Map.new(images, fn {cx, cz, image} -> {{cx, cz}, image} end)
            state = %{state | storage: RegionStorage.columns(state.storage, columns)}
            changed = Map.keys(columns)
            biomes = Map.new(changed, &{&1, Blocks.encode_biomes(state.blocks, &1)})

            # Readers see the new biomes (rain) before clients do.
            state = publish_block_snapshots(state, changed)

            for {chunk, {:ok, bytes}} <- biomes,
                do: Valimc.World.publish(route_key(state), {:chunks_biomes, [{chunk, bytes}]})

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
        epoch != state.epoch ->
          Error.retry(:stale_owner)

        Enum.any?(chunks, fn {cx, cz} -> Grid.region_key({cx, cz}) != state.key end) ->
          {:error, :wrong_region}

        absent_positions?(state, for({cx, cz} <- chunks, do: {cx * 16, 0, cz * 16})) ->
          Error.retry(:chunk_generating)

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

  def handle_call({:light_image, epoch, chunk}, _from, %{epoch: epoch} = state),
    do: {:reply, Blocks.light_image(state.blocks, chunk), state}

  def handle_call({:destroy_block, epoch, revision, position, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      not fence_current?(state, revision) ->
        {:reply, {:error, :stale_revision}, state}

      not (is_integer(deadline) and now < deadline and
               deadline <= now + Valimc.Txn.Permits.window(250)) ->
        {:reply, {:error, :expired_destruction}, state}

      absent_positions?(state, [position]) ->
        {:reply, Error.retry(:chunk_generating), want_positions(state, [position])}

      true ->
        remove_block(state, position, from)
    end
  end

  def handle_call({:block_entity, epoch, position}, _from, state) do
    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

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
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

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
      epoch != state.epoch -> {:reply, Error.retry(:stale_owner), state}
      not valid_block_query?([position], :any) -> {:reply, {:error, :invalid_block_query}, state}
      true -> {:reply, {:ok, preserved_update(state, position)}, state}
    end
  end

  def handle_call({:correct_blocks, epoch, positions, connection}, from, state) do
    if is_pid(connection) and valid_block_query?(positions, :any) and length(positions) <= 2 do
      case handle_call({:observe_blocks, epoch, positions, :any}, from, state) do
        {:reply, {:ok, observed}, state} ->
          for {position, block} <- observed.blocks,
              do: Valimc.Player.PlayerList.deliver(connection, {:block, position, block})

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
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      not fence_current?(state, revision) ->
        {:reply, {:error, :stale_revision}, state}

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
      epoch != state.epoch -> {:reply, Error.retry(:stale_owner), state}
      not box_in_region?(state, min, max) -> {:reply, {:error, :wrong_region}, state}
      box_absent?(state, min, max) -> {:reply, Error.retry(:chunk_generating), state}
      true -> {:reply, Blocks.read_box(state.blocks, min, max), state}
    end
  end

  def handle_call({:prepare_box, epoch, token, edits, expected, entries}, from, state),
    do: handle_call({:prepare_box, epoch, token, edits, expected, entries, []}, from, state)

  def handle_call({:prepare_box, epoch, token, edits, expected, entries, records}, _from, state) do
    now = System.monotonic_time(:millisecond)
    positions = Enum.uniq(Map.keys(edits) ++ Map.keys(expected))
    entities = MapSet.new(Map.keys(entries))

    planned = fn position ->
      Map.get_lazy(edits, position, fn -> Blocks.get(state.blocks, position) end)
    end

    result =
      cond do
        epoch != state.epoch ->
          Error.retry(:stale_owner)

        not Enum.all?(positions, &owns?(state, &1)) ->
          {:error, :wrong_region}

        absent_positions?(state, positions) ->
          Error.retry(:chunk_generating)

        Blocks.get_many(state.blocks, Map.keys(expected)) != expected ->
          {:error, :stale_revision}

        not Enum.all?(records, &Store.valid_record?(state.key, &1)) ->
          {:error, :invalid_item}

        true ->
          with {:ok, batch} <- BlockBatch.prepare(edits),
               {:ok, _proposal} <- block_proposal(state, batch, [], entities),
               {:ok, _, _} <- BlockEntities.put(state.block_entities, entries, planned) do
            grant = %{
              batch: batch,
              entities: entities,
              cells: MapSet.new(Map.keys(edits)),
              records: records
            }

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
      {:ok, grant} when epoch == state.epoch ->
        if entries != %{} and write_busy(state) != nil do
          {:reply, Error.retry(:box_edit_busy), state}
        else
          state = %{state | permits: Permits.release(state.permits, token)}

          case block_proposal(state, grant.batch, [], grant.entities) do
            {:ok, proposal} ->
              next = state |> publish_blocks(grant.batch, proposal) |> adopt_box_records(grant)

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

  # A box edit part ends by its token, in whichever incarnation holds it.
  def handle_call({:abort_box, _epoch, token}, _from, state),
    do: {:reply, :ok, %{state | permits: Permits.release(state.permits, token)}}

  def handle_call({:bucket, epoch, action}, _from, state) do
    position = elem(action, 1)

    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      not in_region?(state, position) ->
        {:reply, {:error, :invalid_bucket}, state}

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      true ->
        case rule_run(state, %{actions: [action]}) do
          {state, %{results: [result]}} -> {:reply, {:ok, result}, state}
          {state, nil} -> {:reply, Error.retry(:region_busy), state}
        end
    end
  end

  def handle_call({:placement, epoch, item, values, {_, y, _} = position}, _from, state) do
    cond do
      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      not (in_region?(state, position) and Chunk.valid_y?(y) and length(values) == 13 and
             Enum.all?(values, &(&1 in 0..255)) and Valimc.Blocks.Placement.placeable?(item)) ->
        {:reply, {:error, :invalid_placement}, state}

      true ->
        {stores, absent} = rule_reach(state)
        {outputs, _} = comparator_context(state)

        case BlockRules.place(state.blocks, stores, item, values, position, absent, outputs) do
          nil -> {:reply, {:error, :refused}, state}
          writes -> {:reply, {:ok, writes}, state}
        end
    end
  end

  def handle_call({:place_block, epoch, revision, %BlockBatch{} = batch, deadline}, from, state) do
    now = System.monotonic_time(:millisecond)

    expected =
      Map.new(batch.edits, fn {position, _} ->
        {position, Blocks.get(state.blocks, position)}
      end)

    cond do
      # The placed block and at most its other half or the water above it,
      # which the placement rules decided at this revision (`:placement`).
      not (is_integer(deadline) and deadline > now and
             deadline <= now + Valimc.Txn.Permits.window(250) and
               map_size(batch.edits) in 1..3) ->
        {:reply, {:error, :invalid_or_expired_placement}, state}

      not container_metadata_affected?(state.containers, expected, batch.edits) ->
        case handle_call({:set_blocks, epoch, revision, batch}, from, state) do
          {:reply, {:ok, _} = reply, next} -> {:reply, reply, hooks_placed(next, batch)}
          other -> other
        end

      epoch != state.epoch ->
        {:reply, Error.retry(:stale_owner), state}

      not fence_current?(state, revision) ->
        {:reply, {:error, :stale_revision}, state}

      batch.region != state.key ->
        {:reply, {:error, :wrong_region}, state}

      not state.entities.persistent ->
        {:reply, {:error, :transfer_storage_disabled}, state}

      busy = write_busy(state) ->
        {:reply, {:error, busy}, state}

      not isolated_chest_changes?(state, batch) ->
        {:reply, {:error, :unsupported_chest_neighbors}, state}

      true ->
        start_container_blocks(state, from, batch, expected)
    end
  end

  # A placed tripwire hook calculates its line, a diode checks its input
  # (`setPlacedBy`, VMC-047a, VMC-048a).
  defp hooks_placed(state, batch) do
    case for(
           {position, block} <- batch.edits,
           Redstone.placed_by?(block),
           do: {:placed, position}
         ) do
      [] -> state
      actions -> elem(rule_run(state, %{actions: actions}), 0)
    end
  end

  # One block set inside a fenced destruction (`remove_block/3`).
  defp set_block(state, {x, y, z} = position, block) do
    key = Grid.chunk_key(x, z)

    cond do
      Permits.locked?(state.permits, [position], System.monotonic_time(:millisecond)) ->
        {:reply, {:error, :box_edit_pending}, state}

      protected_container_change?(state, %{position => block}) ->
        {:reply, {:error, :occupied_container}, state}

      preserved_change?(state, %{position => block}) ->
        {:reply, {:error, :unsupported_block_entity}, state}

      true ->
        previous_blocks = Blocks.get_many(state.blocks, [position])

        if Grid.region_key(key) == state.key and Chunk.valid_y?(y) and block >= 0 and
             block < Valimc.Protocol.Data.block_state_count() and
             Blocks.put(state.blocks, %{position => block}) == :ok do
          lit = Blocks.light_update(state.blocks, [position])
          state = light_changed(state, Blocks.changed_chunks(lit) -- [key])

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
            |> publish_block_snapshots([key])
            |> release_effect({:raw_block, position, block, previous_blocks, lit})
            |> shape_updates(previous_blocks)

          {:reply, :ok, next}
        else
          {:reply, {:error, :invalid_block}, state}
        end
    end
  end

  defp remove_block(state, position, from) do
    block = Blocks.get(state.blocks, position)
    replacement = Valimc.Blocks.after_removal(block)

    state =
      if in_region?(state, position) and write_busy(state) == nil,
        do: unpack_loot(state, position, 0.0),
        else: state

    if Valimc.Blocks.block_entity(block) != nil and
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
        Valimc.Data.Metrics.add(:chunk_cache_hits)
        {:reply, state.cache[key], state}

      Map.has_key?(state.encodes, key) ->
        Valimc.Data.Metrics.add(:chunk_requests_coalesced)
        {:noreply, %{state | encodes: Map.update!(state.encodes, key, &[from | &1])}}

      true ->
        {:noreply, start_encode(%{state | encodes: Map.put(state.encodes, key, [from])}, key)}
    end
  end

  ## Durability (VMC-077f)

  # Cut a frame of what changed since the last; replies and effects whose frame
  # was already durable (none here) run at once.
  defp commit(state) do
    {storage, released} = RegionStorage.commit(state.storage, parts(state))
    run_released(%{state | storage: storage}, released)
  end

  @doc """
  The group's commit tick (VMC-077j): cut a frame of what changed into the
  outbox and start a checkpoint when one is due.
  """
  def commit_tick(state), do: maybe_checkpoint(commit(state))

  @doc "Cut a frame of what changed into the outbox (the group sends every section's at once)."
  def cut(state), do: commit(state)

  @doc """
  Continue at the group's game tick `tick` (VMC-077j): scheduled ticks keep
  their delays, as vanilla's do across a chunk's unload.
  """
  def rebase(%{game_tick: tick} = state, tick), do: state

  def rebase(state, tick) do
    ticks = ScheduledTicks.rebase(state.scheduled_ticks, state.game_tick, tick)
    %{state | scheduled_ticks: ticks, game_tick: tick}
  end

  @doc """
  The section was handed to the calling group process (VMC-077j): it watches
  its ticket holders, viewers and workers, arms its timers (the group it left
  may stop first, VMC-077y) and tells the scheduler its wants from here.
  """
  def adopted(state) do
    generation = %{state.generation | scheduler: nil, sent: %{}, retry: nil}

    for key <- Map.keys(state.encodes),
        not Jobs.running?(state.jobs, {:encode, key}),
        do: send_after(state, {:retry_encode, key}, 0)

    with %{token: token} <- state.entities.handoff,
         do: send_after(state, {:item_handoff_wake, token}, 0)

    %{
      state
      | tickets: Tickets.remonitor(state.tickets),
        container_viewers: ContainerViewers.remonitor(state.container_viewers),
        jobs: Jobs.watch(state.jobs),
        generation: generation
    }
  end

  # Commit, send and wait until the frames are appended, then checkpoint
  # (`detach: true`, a section its group unloads: until its task holds the
  # file, which then outlives it; a flush or shutdown until it is written).
  defp save_now(state, opts \\ [])
  defp save_now(%{storage: %{base: nil}} = state, _opts), do: commit(state)

  defp save_now(state, opts) do
    state = commit(state)
    # An unload whose checkpoint holds its frames waits for them only when a
    # reply depends on them.
    sync = !opts[:detach] or RegionStorage.waiting?(state.storage)
    state = %{state | storage: RegionStorage.send_now(state.storage, sync)}
    state = if sync, do: drain_durable(state), else: state

    if Valimc.World.Saving.auto?(),
      do: %{
        state
        | storage:
            RegionStorage.checkpoint(state.storage, parts(state), state.blocks,
              wait: if(opts[:detach], do: :locked, else: :written)
            )
      },
      else: state
  end

  # This section's durable acknowledgements already in the mailbox (after a
  # sync); its group's other sections and players take theirs as a message.
  defp drain_durable(%{storage: %{owner: owner}} = state) do
    receive do
      {:storage_durable, [{^owner, _} | _] = acks} ->
        {mine, others} = Enum.split_with(acks, &(elem(&1, 0) == owner))
        if others != [], do: send(self(), {:storage_durable, others})
        {:noreply, state} = durable(state, mine |> Enum.map(&elem(&1, 1)) |> Enum.max())
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
      do: %{
        state
        | storage:
            RegionStorage.checkpoint(state.storage, parts(state), state.blocks,
              wrap: &{:resource, state.epoch, &1}
            )
      },
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

  # A reply a cross-owner step depends on (an entity handoff's departure or
  # arrival) waits for its frame to be durable; everything else replies now.
  # Their frame is cut at once rather than at the next commit tick.

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

    # Only chunks a simulation ticket covers tick (VMC-077w: most of a large
    # view does not).
    if Tickets.simulating?(state.tickets),
      do: simulated_block_ticks(state, tick),
      else: retry_rule_backlog(state)
  end

  defp simulated_block_ticks(state, tick) do
    state = post_process(state)

    # Only chunks a simulation ticket covers tick; due ticks elsewhere wait
    # untouched (vanilla's `LevelTicks`).
    {due, scheduled} =
      ScheduledTicks.take_due(state.scheduled_ticks, tick, state.tickets.simulated)

    state = %{state | scheduled_ticks: scheduled}
    state = state |> retry_rule_backlog() |> containers_changed()
    read = &read_block(state, &1)

    # Fluid ticks run in the block rules after the block ticks (VMC-031a).
    {fluid_due, due} = Enum.split_with(due, &match?({_, {:fluid, _}}, &1))
    fluid_due = for {position, {:fluid, kind}} <- fluid_due, do: {position, kind}

    # A tick runs while its cell holds the block it was scheduled for, with
    # the cell's state (`LevelTicks`, VMC-047a). A tick a behaviour handles
    # runs it; the block rules run the others (dependent blocks, VMC-029c,
    # and redstone's components).
    {behaviour_due, rule_due} =
      due
      |> Enum.flat_map(fn {position, key} ->
        current = Blocks.get(state.blocks, position)

        if Valimc.Data.Blocks.block_id(current) == Valimc.Data.Blocks.block_id(key),
          do: [{position, current}],
          else: []
      end)
      |> Enum.split_with(fn {_, block} ->
        module = state.tick_index[block]
        module != nil and function_exported?(module, :scheduled_tick, 4)
      end)

    scheduled_effects =
      for {position, block} <- behaviour_due,
          effect <- state.tick_index[block].scheduled_tick(position, block, read, &random/1),
          do: effect

    {random_effects, lava, growing} = random_ticks(state, read)

    # Plates, buttons and tripwire check the entities on them at their ticks.
    entities =
      if Enum.any?(rule_due, fn {_, block} -> Redstone.checks?(block) end),
        do: contact_entities(state),
        else: []

    state
    |> rule_run(%{
      ticks: rule_due,
      fluid_ticks: fluid_due,
      redstone: redstone_context(state, [], entities)
    })
    |> elem(0)
    |> daylight_ticks(tick)
    |> rule_random_ticks(lava, growing)
    |> apply_tick_effects(scheduled_effects ++ random_effects)
  end

  # Containers whose signal changed since comparators last heard tell them
  # (VMC-048a, `setChanged`'s `updateNeighbourForOutputSignal`); vanilla tells
  # them at the change itself, a tick earlier at most.
  defp containers_changed(%{containers: same, containers_seen: same} = state), do: state

  defp containers_changed(%{containers_seen: nil} = state),
    do: %{state | containers_seen: state.containers}

  defp containers_changed(state) do
    seen = state.containers_seen.entries

    changed =
      for {position, entry} <- state.containers.entries,
          entry !== Map.get(seen, position),
          Redstone.entry_signal(Map.get(seen, position)) != Redstone.entry_signal(entry),
          do: {:output_changed, position}

    state = %{state | containers_seen: state.containers}

    if changed == [],
      do: state,
      else: elem(rule_run(state, %{actions: Enum.sort(changed)}), 0)
  end

  # Daylight detectors' block entities (VMC-047a), every twentieth game tick
  # in a dimension with sky light, in the chunks that tick.
  defp daylight_ticks(state, tick) when rem(tick, 20) != 0, do: state

  defp daylight_ticks(state, _tick) do
    if Valimc.World.Dimension.facts(state.dimension).sky_light do
      detectors =
        for chunk <- state.tickets.simulated,
            Grid.region_key(chunk) == state.key,
            not RegionGeneration.absent?(state.generation, chunk),
            {position, _} <- Blocks.find(state.blocks, chunk, Redstone.detectors()),
            do: {:daylight, position}

      if detectors == [] do
        state
      else
        weather = Clock.weather()

        context =
          state
          |> redstone_context([], [])
          |> Map.put(:day, {Clock.day_ticks(), weather.rain_level, weather.thunder_level})

        elem(rule_run(state, %{actions: Enum.sort(detectors), redstone: context}), 0)
      end
    else
      state
    end
  end

  # The entities' contacts with plates, buttons and tripwire (VMC-047a), once
  # a tick after they moved: vanilla checks them as an entity moves
  # (`checkInsideBlocks`), along its path.
  defp redstone_contacts(state) do
    case contact_entities(state) do
      [] ->
        state

      entities ->
        input = %{actions: [:contacts], redstone: redstone_context(state, [], entities)}
        elem(rule_run(state, input), 0)
    end
  end

  # What redstone sees of the section's entities and the players standing in
  # it: their boxes (players standing, 0.6 by 1.8) and kinds. Spectators are
  # not among the targets.
  defp contact_entities(state) do
    players =
      for {{x, y, z}, _} <- state.player_targets,
          Grid.region_key(Grid.chunk_key(floor(x), floor(z))) == state.key,
          do: {{x - 0.3, y, z - 0.3}, {x + 0.3, y + 1.8, z + 0.3}, :living}

    others =
      for {_, entry} <- state.entities.store.entries,
          box = Redstone.entity_box(entry),
          do: box

    players ++ others
  end

  # The redstone context of a run (`BlockRules.run/4`): the game time, the
  # torches' toggles, the entities checks see, and the owner's pending ticks
  # at the cells its actions name (a target's: a hit waits for its tick).
  defp redstone_context(state, actions, entities) do
    pending =
      for {:hit, position, _, _} <- actions,
          current = read_block(state, position),
          current != nil,
          key =
            Valimc.Data.Blocks.default_state(
              Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(current))
            ),
          ScheduledTicks.scheduled?(state.scheduled_ticks, position, key),
          do: {position, Valimc.Data.Blocks.block_id(current)}

    # Toggles older than 60 ticks count for nothing (a torch's tick drops
    # them first), so they need not be kept.
    toggles = Enum.filter(state.torch_toggles, fn {_, at} -> state.game_tick - at <= 60 end)
    {outputs, containers} = comparator_context(state)

    %{
      time: state.game_tick,
      toggles: toggles,
      entities: entities,
      pending: pending,
      outputs: outputs,
      containers: containers
    }
  end

  # The group's comparators' outputs, and the signals of the containers one
  # or two cells beside them (VMC-048a: what a comparator reads, also through
  # a conductor).
  defp comparator_context(state) do
    sections =
      [{state.key, state.comparators, state.containers}] ++
        for {key, peer} <- state.siblings,
            key != state.key,
            comparators = Map.get(peer, :comparators, %{}),
            containers = Map.get(peer, :containers, %Valimc.World.Containers{}),
            map_size(comparators) > 0 or map_size(containers.entries) > 0,
            do: {key, comparators, containers}

    case Enum.flat_map(sections, fn {_, comparators, _} -> Map.to_list(comparators) end) do
      [] ->
        {[], []}

      outputs ->
        entries = Map.new(sections, fn {key, _, containers} -> {key, containers.entries} end)

        containers =
          for {{x, y, z}, _} <- outputs,
              {dx, dz} <- [{1, 0}, {2, 0}, {-1, 0}, {-2, 0}, {0, 1}, {0, 2}, {0, -1}, {0, -2}],
              position = {x + dx, y, z + dz},
              entry = get_in(entries, [Grid.region_key(Grid.chunk_key(x + dx, z + dz)), position]),
              entry != nil,
              uniq: true,
              do: {position, Redstone.entry_signal(entry)}

        {outputs, containers}
    end
  end

  # The owner's pending ticks at the cells a run's changes name, for the old
  # and new block there (an observer's onPlace and removal ask).
  defp change_pending(_state, changes) when map_size(changes) == 0, do: []

  defp change_pending(state, changes) do
    for {position, old} <- changes,
        state_id <- Enum.uniq([old, read_block(state, position)]),
        state_id != nil,
        block = Valimc.Data.Blocks.block_id(state_id),
        key = Valimc.Data.Blocks.default_state(Valimc.Data.Blocks.name(block)),
        ScheduledTicks.scheduled?(state.scheduled_ticks, position, key),
        do: {position, block}
  end

  # Lava's (VMC-031a) and growing plants' (VMC-039a) random ticks run in the
  # block rules: fire spreads from lava only near a player (the
  # `fire_spread_radius_around_player` game rule, `canSpreadFireAround`);
  # saplings read the day's sky darkening.
  defp rule_random_ticks(state, [], []), do: state

  defp rule_random_ticks(state, lava, growing) do
    radius = Valimc.World.GameRules.get(:fire_spread_radius_around_player)

    near? = fn {x, y, z} ->
      radius == -1 or
        Enum.any?(state.player_targets, fn {{px, py, pz}, _} ->
          :math.sqrt((px - x) ** 2 + (py - y) ** 2 + (pz - z) ** 2) < radius
        end)
    end

    actions =
      for(p <- lava, do: {:random_tick, p, near?.(p), false}) ++
        Valimc.World.Growth.random_ticks(state.dimension, growing)

    weather = Clock.weather()

    context =
      state
      |> redstone_context([], [])
      |> Map.put(:day, {Clock.day_ticks(), weather.rain_level, weather.thunder_level})

    {state, outcome} = rule_run(state, %{actions: actions, redstone: context})
    Valimc.World.Growth.grow(state.dimension, actions, outcome)
    state
  end

  # Generated chunks' post-processing marks (`LevelChunk.postProcessGeneration`,
  # VMC-031a), once a chunk ticks with its eight neighbours generated in the
  # group: each mark's fluid ticks at once and its block takes its neighbours'
  # shape, then the chunk's generation fluid ticks are due. A mark whose run
  # read past the group stays for a later tick.
  defp post_process(%{post: post} = state) when map_size(post) == 0, do: state

  defp post_process(state) do
    ready =
      for {chunk, _} <- state.post,
          Tickets.simulated?(state.tickets, chunk),
          neighbours_present?(state, chunk),
          do: chunk

    if ready == [] do
      state
    else
      marks = for chunk <- ready, {x, y, z} <- elem(state.post[chunk], 0), do: {x, y, z}
      actions = for position <- marks, do: {:post, position}
      {state, outcome} = rule_run(state, %{actions: actions})

      kept =
        if outcome,
          do: for({position, 0} <- Enum.zip(marks, outcome.results), do: position),
          else: marks

      ticks =
        for chunk <- ready,
            {position, name} <- elem(state.post[chunk], 1),
            do: {:schedule, position, {:fluid, Valimc.Blocks.Fluids.id(name)}, 0, 0}

      kept_by_chunk = Enum.group_by(kept, fn {x, _, z} -> Grid.chunk_key(x, z) end)

      post =
        Enum.reduce(ready, state.post, fn chunk, acc ->
          case kept_by_chunk do
            %{^chunk => marks} -> Map.put(acc, chunk, {marks, []})
            _ -> Map.delete(acc, chunk)
          end
        end)

      schedule_ticks(%{state | post: post}, ticks)
    end
  end

  # Whether `chunk`'s eight neighbours are generated in this section or a
  # sibling section of the group.
  defp neighbours_present?(state, {cx, cz}) do
    Enum.all?(for(dx <- -1..1, dz <- -1..1, do: {cx + dx, cz + dz}), fn chunk ->
      key = Grid.region_key(chunk)

      cond do
        key == state.key -> not RegionGeneration.absent?(state.generation, chunk)
        sibling = state.siblings[key] -> chunk not in sibling.absent
        true -> false
      end
    end)
  end

  # Vanilla picks `randomTickSpeed` positions per section per tick (the gamerule,
  # `:random_tick_speed`); the native sampler skips sections without handled
  # states and returns only hits.
  # The sampled cells' behaviour effects, the lava cells among them and the
  # growing plants.
  defp random_ticks(state, read) do
    hits =
      for {{x, _, z} = position, block} <-
            Blocks.random_ticks(state.blocks, state.random_tick_speed),
          Tickets.simulated?(state.tickets, Grid.chunk_key(x, z)),
          in_region?(state, position),
          do: {position, block}

    {lava, others} = Enum.split_with(hits, fn {_, block} -> block in @lava_states end)

    {growing, others} =
      Enum.split_with(others, fn {_, block} -> Valimc.World.Growth.growing?(block) end)

    effects =
      for {position, block} <- others,
          module = state.tick_index[block],
          effect <- module.random_tick(position, block, read, &random/1),
          do: effect

    {effects, for({position, _} <- lava, do: position), growing}
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
  # dependent blocks' due `ticks`, across the group's sections (VMC-077j):
  # the run stops only at the group's edge. Each section's writes commit as
  # one batch, with the loot of the blocks they destroyed, in the group's next
  # frame; that batch starts no updates of its own. Behind a running item
  # plan in a section the run drops loot in, it waits for the next tick,
  # whole.
  defp rule_updates(state, previous, []) when map_size(previous) == 0, do: state

  defp rule_updates(state, previous, ticks),
    do: elem(rule_run(state, %{changes: previous, ticks: ticks}), 0)

  # One block-rule run (`BlockRules.run/4`) over this section and its
  # siblings with the dimension's fluid settings: the state with its outcome
  # applied, and the outcome (nil when it waits in the backlog, and for a run
  # with nothing to do).
  defp rule_run(state, input) do
    work = Map.drop(input, [:redstone, :actor])

    if Enum.all?(work, fn {_, value} -> value == [] or value == %{} end) do
      {state, nil}
    else
      siblings = Map.delete(state.siblings, state.key)
      {stores, absent} = rule_reach(state)

      input =
        input
        |> Map.put(:options, fluid_options(state))
        |> Map.put_new_lazy(:redstone, fn ->
          redstone_context(state, Map.get(input, :actions, []), [])
        end)
        |> Map.update!(:redstone, fn context ->
          Map.update(
            context,
            :pending,
            [],
            &(&1 ++ change_pending(state, Map.get(input, :changes, %{})))
          )
        end)

      outcome = BlockRules.run(state.blocks, stores, input, absent)
      parts = by_section(outcome, state)

      busy =
        Enum.any?(parts, fn {key, part} ->
          Enum.any?(part.destroyed, &elem(&1, 2)) and
            if(key == state.key, do: write_busy(state) != nil, else: siblings[key].busy)
        end)

      cond do
        busy and Map.get(input, :actions, []) != [] ->
          {state, nil}

        busy ->
          {%{state | rule_backlog: [input | state.rule_backlog]}, nil}

        true ->
          {own, theirs} = Map.pop(parts, state.key)
          state = play_redstone(%{state | torch_toggles: outcome.toggles}, outcome, input)
          state = if own, do: apply_rules(state, own), else: state
          effects = for {key, part} <- theirs, do: {key, {:rules, part}}
          {%{state | sibling_effects: state.sibling_effects ++ effects}, outcome}
      end
    end
  end

  # The rules' level settings: the dimension's fluid attributes, the source
  # conversion game rules and whether TNT explodes (VMC-047a).
  defp fluid_options(state) do
    Valimc.Blocks.Fluids.options(
      Valimc.World.Dimension.facts(state.dimension).type,
      Valimc.World.GameRules.get(:water_source_conversion),
      Valimc.World.GameRules.get(:lava_source_conversion)
    ) ||| if(Valimc.World.GameRules.get(:tnt_explodes), do: 16, else: 0)
  end

  # A run's sounds and note blocks' block events (VMC-047a), to the players
  # near them; a sound the acting player already played (its client's) skips
  # that player's connection. A note block's event plays its instrument
  # (`triggerEvent`) while the cell still holds a note block.
  defp play_redstone(state, %{sounds: [], block_events: []}, _input), do: state

  defp play_redstone(state, outcome, input) do
    actor = Map.get(input, :actor)

    for {{x, _, z} = at, index, volume, pitch, by_actor} <- outcome.sounds do
      packet = Redstone.sound_packet(Redstone.sound(index), "block", at, volume, pitch)

      key = Grid.section(state.dimension, Grid.chunk_key(floor(x), floor(z)))
      except = if by_actor, do: actor
      Valimc.World.publish(key, {:sound, at, max(volume, 1.0) * 16.0, packet, except})
    end

    changes = Map.new(outcome.changes)

    for {{x, y, z} = position, block, b0, b1} <- outcome.block_events,
        current = Map.get(changes, position) || read_block(state, position),
        current != nil and Valimc.Data.Blocks.block_id(current) == block,
        {sound, pitch} <- List.wrap(Redstone.note_sound(current)) do
      at = {x + 0.5, y + 0.5, z + 0.5}
      key = Grid.section(state.dimension, Grid.chunk_key(x, z))
      event = Valimc.Protocol.Packets.block_event(position, b0, b1, block)

      sound = Redstone.sound_packet(sound, "record", at, 3.0, pitch)

      Valimc.World.publish(key, {:sound, at, 64.0, event, nil})
      Valimc.World.publish(key, {:sound, at, 48.0, sound, nil})
    end

    state
  end

  # What the block rules read beyond this section: the group's other
  # sections' stores, and every chunk of the group not generated yet.
  defp rule_reach(state) do
    siblings = Map.delete(state.siblings, state.key)
    own = MapSet.to_list(state.generation.absent)
    absent = Enum.reduce(siblings, own, fn {_, sibling}, acc -> sibling.absent ++ acc end)
    {for({_, sibling} <- siblings, do: sibling.blocks), absent}
  end

  # The run's outcome split by the section of each cell; cells outside the
  # group (ticks only) are dropped.
  defp by_section(outcome, state) do
    key = fn {x, _, z} -> Grid.region_key(Grid.chunk_key(x, z)) end

    empty = %{
      changes: [],
      destroyed: [],
      ticks: [],
      fluid_ticks: [],
      events: [],
      primed: [],
      outputs: []
    }

    [
      changes: outcome.changes,
      destroyed: outcome.destroyed,
      ticks: outcome.ticks,
      fluid_ticks: outcome.fluid_ticks,
      events: outcome.events,
      primed: for(cell <- outcome.primed, do: {cell}),
      outputs: outcome.outputs
    ]
    |> Enum.reduce(%{}, fn {field, records}, acc ->
      Enum.reduce(Enum.reverse(records), acc, fn record, acc ->
        section = key.(elem(record, 0))

        if section == state.key or is_map_key(state.siblings, section),
          do:
            Map.update(
              acc,
              section,
              %{empty | field => [record]},
              &Map.update!(&1, field, fn l -> [record | l] end)
            ),
          else: acc
      end)
    end)
  end

  @doc """
  Apply what a section of this group did to this one (VMC-077j): its block
  rules' changes, entities it moved here, or a donor item to merge into
  `target` here. A move that cannot land goes back to `source` the same way.
  """
  def apply_sibling(state, {:rules, part}), do: apply_rules(state, part)
  def apply_sibling(state, {:halo, message}), do: Valimc.World.LightHalo.handle(message, state)

  def apply_sibling(state, {:entities, source, records}) do
    {store, refused} =
      Enum.reduce(records, {state.entities.store, []}, fn record, {store, refused} ->
        with false <- Store.reserved_uuid?(store, record.uuid),
             {:ok, next, _} <- Store.create_record(store, state.key, record) do
          {next, refused}
        else
          _ -> {store, [record | refused]}
        end
      end)

    state
    |> put_entities(store)
    |> return_to(source, Enum.reverse(refused))
  end

  # A sibling's projectile hits a body here (VMC-037o).
  def apply_sibling(state, {:hurt, uuid, hit}), do: elem(hurt_entity(state, uuid, hit), 1)

  # A sibling's explosion reaches this section's entities (VMC-050a).
  def apply_sibling(state, {:explosion, explosion}) do
    store = state.entities.store
    hits = Explosion.hits(explosion, store.entries)
    put_entities(state, Explosion.apply_hits(store, state.key, hits))
  end

  def apply_sibling(state, {:merge, source, target, donor}) do
    case ItemMerges.absorb(state.entities.store, state.key, target, donor) do
      {:ok, store} -> put_entities(state, store)
      :error -> return_to(state, source, [donor])
    end
  end

  @doc """
  The one hurt path for a body of this section (VMC-037n): melee, explosions
  and projectiles hit through `Entity.Combat.hurt/3` (see it for `hit`). A
  death drops at once what `LivingEntity.dropAllDeathLoot` drops: its loot
  table's items (unless `mob_drops` is off) and a player kill's experience.
  `{{:ok, outcome}, state}` (`outcome` without the death) or `{error, state}`.
  """
  def hurt_entity(state, uuid, hit) do
    store = state.entities.store

    with {:ok, {_, id, _}} <- Store.find(store, uuid),
         {:ok, store, outcome} <- Valimc.Entity.Combat.hurt(store, id, hit) do
      {{:ok, outcome}, put_entities(state, store)}
    else
      {:error, _} = error -> {error, state}
    end
  end

  @doc """
  Mob `uuid`'s melee attack on player `target` (`Mob.doHurtTarget`,
  VMC-037n), for VMC-041a's melee goal: the hit goes to the player's session
  in this group, which runs its hurt (`Player.Hurt`). `:ok` or `{:error,
  reason}`.
  """
  def mob_attack(state, uuid, target) do
    store = state.entities.store

    with {:ok, {_, id, _}} <- Store.find(store, uuid),
         {:ok, hit} <- Valimc.Entity.Combat.mob_hit(store, id, "minecraft:player") do
      send(self(), {:player, target, {:hurt, hit}})
      :ok
    end
  end

  @doc """
  Mob `uuid`'s arrow at `target` (`AbstractSkeleton.performRangedAttack`,
  VMC-037o), for VMC-043b's ranged goal: an arrow from its eyes (`power`
  from the bow's draw, `BowItem.getPowerForTime`) aimed at a third of the
  target's height (`{x, y, z, height}`) and raised for the distance, shot at
  1.6 with the difficulty's spread, damage `2 × power` plus a little for the
  difficulty, and the skeleton's shot sound. `{:ok, state}` or `{:error,
  reason}`.
  """
  def mob_shoot(state, uuid, {tx, ty, tz, height}, power \\ 1.0) do
    store = state.entities.store

    with {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{kind: :mob, body: %Body{type: type} = body, entity: e} <- store.entries[id],
         true <- Body.alive?(body) do
      difficulty = elem(Clock.difficulty(), 0).level
      eye = Valimc.Data.EntityTypes.fetch(type).eye_height

      {x, y, z} =
        {e.x * 1.0, Valimc.Data.Float32.round(e.y + eye) - 0.10000000149011612, e.z * 1.0}

      owner = %{uuid: e.uuid, id: e.entity_id, player: false, type: type}
      arrow = Projectile.new("minecraft:arrow", owner, Valimc.Protocol.ItemStack.new("arrow"))

      # `setBaseDamageFromMob`: `power * 2 + triangle(difficulty * 0.11, 0.57425)`.
      damage =
        Valimc.Data.Float32.round(power * 2.0) + difficulty * 0.11 +
          0.57425 * (:rand.uniform() - :rand.uniform())

      arrow = %{arrow | data: %{arrow.data | damage: damage}}
      {xd, zd} = {tx - e.x, tz - e.z}
      distance = :math.sqrt(xd * xd + zd * zd)
      yd = ty + height / 3.0 - y + distance * Valimc.Data.Float32.round(0.2)
      arrow = Projectile.shoot(arrow, {xd, yd, zd}, 1.6, 14 - difficulty * 4)
      record = Store.body_record(arrow, :crypto.strong_rand_bytes(16), {x, y, z})

      case Store.create_record(store, state.key, record) do
        {:ok, store, _} ->
          pitch =
            Valimc.Data.Float32.round(
              1.0 / Valimc.Data.Float32.round(:rand.uniform() * 0.4 + 0.8)
            )

          state = put_entities(state, store)

          {:ok,
           projectile_effect(
             state,
             nil,
             {:sound, "minecraft:entity.skeleton.shoot", "hostile", {e.x, e.y, e.z}, 1.0, pitch}
           )}

        error ->
          error
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :no_shooter}
    end
  end

  # `dropFromLootTable` (the owner's random stands in for the world's random
  # sequence of the table) and `ExperienceOrb.award`, where the mob died.
  defp drop_death(store, key, {death, {x, y, z} = position}) do
    drops = Valimc.World.GameRules.get(:mob_drops)
    death = Map.put(death, :position, position)

    stacks =
      with true <- drops and death.loot_table != nil and not death.loot.baby,
           <<seed::signed-64>> = :crypto.strong_rand_bytes(8),
           {:ok, stacks} <-
             Valimc.Blocks.Loot.entity_drops(death.loot_table, seed, death.position, death.loot) do
        stacks
      else
        _ -> []
      end

    items =
      for stack <- stacks do
        [vx, vz] = for _ <- 1..2, do: :rand.uniform_real()

        %{
          uuid: :crypto.strong_rand_bytes(16),
          x: x,
          y: y,
          z: z,
          stack: stack,
          motion: %Valimc.Entity.ItemMotionState{
            velocity: {vx * 0.2 - 0.1, 0.2, vz * 0.2 - 0.1},
            pickup_delay: 10
          }
        }
      end

    orbs = if drops, do: ExperienceOrbs.drop(death.position, death.experience), else: []

    Enum.reduce(items ++ orbs, store, fn record, acc ->
      case Store.create_record(acc, key, record) do
        {:ok, next, _} -> next
        {:error, _} -> acc
      end
    end)
  end

  defp put_entities(state, store) when store == state.entities.store, do: state

  # Every hurt path's deaths drop here, as `LivingEntity.die` drops them.
  defp put_entities(state, store) do
    {store, deaths} = Store.take_deaths(store)
    store = Enum.reduce(deaths, store, &drop_death(&2, state.key, &1))
    publish_item_views(%{state | entities: %{state.entities | store: store}})
  end

  defp return_to(state, _source, []), do: state

  defp return_to(state, nil, records) do
    require Logger
    Logger.error("Entities lost between sections: #{inspect(Enum.map(records, & &1.uuid))}")
    state
  end

  defp return_to(state, source, records),
    do: %{state | sibling_effects: state.sibling_effects ++ [{source, {:entities, nil, records}}]}

  # Whether entities moving to section `destination` go there directly: it is
  # a section of this group and no plan holds either store (a plan's result
  # replaces its store whole).
  defp local_destination?(state, {dimension, sx, sz}) do
    dimension == state.dimension and write_busy(state) == nil and
      match?(%{busy: false}, state.siblings[{sx, sz}]) and {sx, sz} != state.key
  end

  # Store moving to a section of this group go there in the same group
  # commit (VMC-077j): withdrawn here, their hops counted as a handoff counts
  # them, and adopted there once this call returns, with a fresh tracker
  # (observers resync to the new epoch); no intent, no receipt.
  defp move_to_sibling(state, {_, sx, sz}, steps) do
    with {:ok, moved, handles} <-
           Store.advance(state.entities.store, {sx, sz}, state.entities.store.epoch, steps),
         {:ok, store, records} <- Store.withdraw(moved, handles) do
      Valimc.Data.Metrics.add(:item_section_moves, length(records))
      effect = {{sx, sz}, {:entities, state.key, records}}

      %{
        state
        | entities: %{state.entities | store: store},
          sibling_effects: state.sibling_effects ++ [effect]
      }
    else
      _ -> state
    end
  end

  # A cross-section merge inside the group: the donor leaves here and merges
  # into `target` there, or comes back.
  defp merge_into_sibling(state, {_, sx, sz}, {id, revision}, target) do
    case Store.withdraw(state.entities.store, [{state.entities.store.epoch, id, revision}]) do
      {:ok, store, [donor]} ->
        Valimc.Data.Metrics.add(:item_cross_merges)
        effect = {{sx, sz}, {:merge, state.key, target, donor}}

        %{
          state
          | entities: %{state.entities | store: store},
            sibling_effects: state.sibling_effects ++ [effect]
        }

      _ ->
        state
    end
  end

  @doc """
  Apply the block rules' changes, destroyed blocks and ticks in this section
  (`rule_run/2`'s, here or from a sibling section's run, VMC-077j).
  """
  def apply_rules(state, %{changes: changes, destroyed: destroyed, ticks: ticks} = part) do
    drops = for {position, block, true, _} <- destroyed, do: {position, block}
    breaks = for {position, block, _, true} <- destroyed, do: {position, block}
    changes = Map.new(changes)

    fluid_ticks =
      for {position, kind, delay} <- part.fluid_ticks,
          in_region?(state, position),
          do: {:schedule, position, {:fluid, kind}, delay, 0}

    state
    |> schedule_ticks(rule_ticks(state, changes, ticks) ++ fluid_ticks)
    |> commit_rule_changes(changes, drops, breaks)
    |> rule_events(part.events)
    |> prime_tnt(for({cell} <- Map.get(part, :primed, []), do: cell))
    |> put_outputs(Map.get(part, :outputs, []))
  end

  # Comparators' outputs the rules changed (VMC-048a): nil for one gone.
  defp put_outputs(state, []), do: state

  defp put_outputs(state, outputs) do
    comparators =
      Enum.reduce(outputs, state.comparators, fn
        {position, nil}, acc -> Map.delete(acc, position)
        {position, output}, acc -> Map.put(acc, position, output)
      end)

    %{state | comparators: comparators}
  end

  # TNT that power primed (VMC-047a, `TntBlock.prime`): a primed TNT with
  # vanilla's 80-tick fuse at each cell's bottom centre, in this frame.
  defp prime_tnt(state, []), do: state

  defp prime_tnt(state, cells) do
    records = for cell <- cells, do: Valimc.World.Explosion.primed_record(cell, 80)

    if planning?(state),
      do: %{state | entities: %{state.entities | dropped: state.entities.dropped ++ records}},
      else: adopt_drops(state, records)
  end

  # The level events a run raised (lava fizzing, VMC-031a).
  defp rule_events(state, []), do: state
  defp rule_events(state, events), do: release_effect(state, {:level_events, events})

  # The rules schedule a block's tick, as vanilla does: keyed by its block's
  # default state (a cell and block pending once), it runs while the cell
  # holds that block, with the cell's state then (VMC-047a).
  defp rule_ticks(_state, _changes, []), do: []

  defp rule_ticks(state, _changes, ticks) do
    for {position, block, delay, priority} <- ticks,
        in_region?(state, position),
        do:
          {:schedule, position, Valimc.Data.Blocks.default_state(Valimc.Data.Blocks.name(block)),
           delay, priority}
  end

  defp retry_rule_backlog(%{rule_backlog: []} = state), do: state

  defp retry_rule_backlog(state) do
    if write_busy(state) != nil do
      state
    else
      backlog = Enum.reverse(state.rule_backlog)

      Enum.reduce(backlog, %{state | rule_backlog: []}, fn input, acc ->
        elem(rule_run(acc, input), 0)
      end)
    end
  end

  defp commit_rule_changes(state, edits, _drops, _breaks) when map_size(edits) == 0, do: state

  defp commit_rule_changes(state, edits, [], _breaks) do
    with {:ok, batch} <- BlockBatch.prepare(edits),
         {:ok, proposal} <- block_proposal(state, batch) do
      publish_blocks(state, batch, proposal, false, false)
    else
      _ -> state
    end
  end

  # Destroyed blocks break like vanilla `destroyBlock` (or, with no particles
  # and sound, `removeBlock` after `dropResources`): they leave their fluid and
  # drop their tool-less loot, in the frame that writes the rules' changes.
  defp commit_rule_changes(state, edits, drops, breaks) do
    # Each destroyed block's loot reads its neighbours as vanilla destroys them
    # in order: the ones destroyed before it already gone.
    {items, _} =
      Enum.reduce(drops, {state.entities.store, %{}}, fn {position, _} = drop, {items, gone} ->
        read = fn cell -> Map.get(gone, cell) || read_block(state, cell) end
        items = add_support_drops(items, state.key, drop, read)
        {items, Map.put(gone, position, Map.get(edits, position))}
      end)

    with {:ok, batch} <- BlockBatch.prepare(edits),
         {:ok, proposal} <- block_proposal(state, batch) do
      {state, effects} = apply_blocks(state, batch, proposal, false, false)
      state = publish_item_views(%{state | entities: %{state.entities | store: items}})

      state
      |> release_blocks(effects)
      |> release_effect({:level_events, for({p, b} <- breaks, do: {p, 2001, b})})
    else
      _ -> state
    end
  end

  # A tool-less break's loot (VMC-029e), each stack popping like vanilla
  # `Block.popResource` (`Valimc.Entity.ItemDrop.pop/2`).
  defp add_support_drops(items, key, {{x, y, z} = position, block}, read) do
    stacks =
      case Valimc.Blocks.MiningLoot.drops(block, position,
             above: read.({x, y + 1, z}),
             below: read.({x, y - 1, z})
           ) do
        {:ok, stacks} -> stacks
        {:error, _} -> []
      end

    Enum.reduce(stacks, items, fn stack, acc ->
      record = Valimc.Entity.ItemDrop.pop(position, stack)

      case Store.create_record(acc, key, record) do
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
    chunk = Grid.chunk_key(x, z)

    Grid.region_key(chunk) == state.key and Chunk.valid_y?(y) and
      not RegionGeneration.absent?(state.generation, chunk)
  end

  defp absent_positions?(state, positions),
    do:
      RegionGeneration.any_absent?(
        state.generation,
        Enum.map(positions, fn {x, _, z} -> Grid.chunk_key(x, z) end)
      )

  defp want_positions(state, positions),
    do:
      RegionGeneration.urgent(
        state,
        positions |> Enum.map(fn {x, _, z} -> Grid.chunk_key(x, z) end) |> Enum.uniq()
      )

  defp apply_tick_effects(state, []), do: state

  defp apply_tick_effects(state, effects) do
    state = schedule_ticks(state, effects)
    edits = for {:set, position, block} <- effects, into: %{}, do: {position, block}

    # A block that falls (VMC-050a2) leaves its fluid and becomes a falling
    # block at its cell's bottom centre (`FallingBlockEntity.fall`).
    falls = for {:fall, position, block} <- effects, do: {position, block}

    edits =
      Enum.reduce(falls, edits, fn {p, b}, acc ->
        Map.put(acc, p, Valimc.Data.BlockFacts.fluid_remains(b))
      end)

    records =
      for {{x, y, z} = position, block} <- falls do
        body = Body.falling_block(Valimc.Blocks.FallingBlock.falling_state(block), position)
        Store.body_record(body, :crypto.strong_rand_bytes(16), {x + 0.5, y * 1.0, z + 0.5})
      end

    commit_landings(state, edits, records)
  end

  defp schedule_ticks(state, effects) do
    Enum.reduce(effects, state, fn
      {:schedule, position, block, delay, priority}, acc ->
        {:ok, ticks} =
          ScheduledTicks.schedule(
            acc.scheduled_ticks,
            position,
            block,
            acc.game_tick + delay,
            priority
          )

        %{acc | scheduled_ticks: ticks}

      _, acc ->
        acc
    end)
  end

  defp item_request(epoch, from, state, work) do
    cond do
      epoch != state.epoch -> {:reply, Error.retry(:stale_owner), state}
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
      true -> item_result(work.(), from, state)
    end
  end

  defp item_result({:ok, items, {epoch, id, revision}}, from, state) do
    reply = {:ok, {self(), epoch, id, revision}}

    if items == state.entities.store,
      do: {:reply, reply, state},
      else: commit_items(items, reply, from, state)
  end

  defp item_result({:ok, items}, from, state), do: commit_items(items, :ok, from, state)

  defp item_result({:ok, items, handles}, from, state) when is_list(handles) do
    handles = Enum.map(handles, fn {epoch, id, revision} -> {self(), epoch, id, revision} end)

    if items == state.entities.store,
      do: {:reply, {:ok, handles}, state},
      else: commit_items(items, {:ok, handles}, from, state)
  end

  defp item_result({:error, _} = error, _from, state), do: {:reply, error, state}

  # Store are adopted at once and the caller is answered at
  # once (D2); the next frame holds their records (VMC-077f).
  defp commit_items(items, reply, from, state) do
    state = publish_item_views(%{state | entities: %{state.entities | store: items}})

    {:noreply, finish_item_reply(state, from, reply)}
  end

  @doc """
  Why a new durable mutation cannot start now: the planning slot is taken
  (`{:retry, :item_storage_busy}`). `nil` when it may start.
  """
  def write_busy(state), do: if(planning?(state), do: {:retry, :item_storage_busy})

  defp release_effect(state, {:blocks, effects}), do: release_blocks(state, effects)
  # Only the resume registered with the current outgoing record acts: a newer
  # record has its own, released once that record is durable.
  defp release_effect(state, {:resume_item_handoff, outgoing}) do
    if state.entities.store.ledger.outgoing == outgoing,
      do: resume_item_handoff(state),
      else: state
  end

  defp release_effect(state, {:generation_handed_over, chunks}),
    do: RegionGeneration.handed_over(state, chunks)

  defp release_effect(state, {:deliver, pid, message}) do
    Valimc.Player.PlayerList.deliver(pid, message)
    state
  end

  defp release_effect(state, {:level_events, events}) do
    Valimc.World.publish(route_key(state), {:level_events, events})
    state
  end

  defp release_effect(state, {:raw_block, position, block, previous, lit}) do
    state = retire_container_changes(state, %{position => block}, previous)
    Valimc.World.publish(route_key(state), {:block, position, block})

    if lit != [],
      do:
        Valimc.World.publish(
          route_key(state),
          {:block_batch, Valimc.World.LightHalo.frames(state, lit, :border)}
        )

    Valimc.World.LightHalo.forward(state, %{position => block})
    Valimc.Data.Metrics.add(:block_edits)
    state
  end

  defp release_effect(state, {:container_changed, position}),
    do: notify_container_changed(state, position)

  defp release_effect(state, {:experience_pickup, %{id: id, collector: collector}}) do
    Valimc.World.publish(route_key(state), {:experience_pickup, state.epoch, id, collector})
    state
  end

  # Publishes the store's views between ticks; new entities get their tracker
  # here, so the spawn observers read and the frames that follow agree.
  @doc """
  The players standing in the section and their packets of this tick
  (`Valimc.Player.Host.track/1`): published with the entities' rows and
  frame.
  """
  def players(state, {views, frame}, targets \\ [], bodies \\ [], sensed \\ []) do
    frame = Map.merge(state.player_frame, frame, fn _, earlier, later -> earlier ++ later end)

    %{
      state
      | player_views: views,
        player_frame: frame,
        player_targets: targets,
        player_bodies: bodies,
        player_sensed: sensed
    }
  end

  defp publish_item_views(state) do
    store = state.entities.store
    tracking = Tracking.sync(state.entities.tracking, store.views, store.ledger.outgoing)
    views = Map.merge(Tracking.published(tracking, store.views), state.player_views)

    :ok =
      Publication.publish(
        state.publication,
        state.epoch,
        tracking.tick,
        views,
        %{},
        store.views
      )

    %{state | entities: %{state.entities | tracking: tracking}}
  end

  # The entities phase's end (VMC-077h): every tracker ticks once, and the frame
  # of their changes is published with the rows.
  # A section without entities or players that published nothing last tick
  # has nothing to publish (VMC-077w): most of a flying player's view.
  defp track_entities(%{entities: %{quiet: true} = entities} = state)
       when entities.store.views == %{} and entities.tracking.trackers == %{} and
              entities.tracking.departing == %{} and state.player_views == %{} and
              state.player_frame == %{},
       do: state

  defp track_entities(state) do
    store = state.entities.store

    {tracking, frame} =
      Tracking.step(
        state.entities.tracking,
        store.views,
        store.ledger.outgoing,
        state.game_tick
      )

    views = Map.merge(Tracking.published(tracking, store.views), state.player_views)
    frame = Map.merge(frame, state.player_frame)

    :ok =
      Publication.publish(
        state.publication,
        state.epoch,
        tracking.tick,
        views,
        frame,
        store.views
      )

    Valimc.Data.Metrics.add(
      :entity_frame_packets,
      Enum.sum(Enum.map(frame, &length(elem(&1, 1))))
    )

    quiet = views == %{} and frame == %{}
    %{state | entities: %{state.entities | tracking: tracking, quiet: quiet}, player_frame: %{}}
  end

  # Players' drops become entities here; a record that cannot (it left the
  # section, a duplicate uuid) is logged and dropped, never retried.
  # The entities a box edit part brings (an explosion's drops and primed
  # TNT) join the store in the edit's frame, or wait for a running plan.
  defp adopt_box_records(state, %{records: [_ | _] = records}) do
    if planning?(state),
      do: %{state | entities: %{state.entities | dropped: state.entities.dropped ++ records}},
      else: adopt_drops(state, records)
  end

  defp adopt_box_records(state, _grant), do: state

  defp adopt_drops(state, records) do
    items =
      Enum.reduce(records, state.entities.store, fn record, items ->
        case Store.create_record(items, state.key, record) do
          {:ok, next, _} ->
            next

          {:error, reason} ->
            require Logger
            Logger.warning("Player drop not adopted: #{inspect(reason)}")
            items
        end
      end)

    publish_item_views(%{state | entities: %{state.entities | store: items}})
  end

  @doc "Publish level events (`{cell, type, data}`) to the section's viewers (VMC-042b: spawner blocks)."
  def publish_level_events(state, events),
    do: Valimc.World.publish(route_key(state), {:level_events, events})

  @doc """
  A tick's natural spawning in this section (VMC-042a, `World.Spawning`):
  it adopts the records of the mobs that spawned (queued like drops while a
  plan runs), discards the mobs that despawn, unless a plan or a write is
  under way (they are checked again next tick), and restarts the idle time
  of those a player came near.
  """
  def spawned(state, records, discards, resets) do
    state =
      cond do
        records == [] ->
          state

        planning?(state) ->
          %{state | entities: %{state.entities | dropped: state.entities.dropped ++ records}}

        true ->
          adopt_drops(state, records)
      end

    store = Store.reset_idle(state.entities.store, resets)

    store =
      if discards == [] or write_busy(state) != nil,
        do: store,
        else:
          Enum.reduce(discards, store, fn id, store ->
            with %{revision: revision} <- store.entries[id],
                 {:ok, next} <- Store.remove(store, store.epoch, id, revision) do
              next
            else
              _ -> store
            end
          end)

    if discards == [] do
      %{state | entities: %{state.entities | store: store}}
    else
      publish_item_views(%{state | entities: %{state.entities | store: store}})
    end
  end

  defp take(items, epoch, id, revision, nil), do: Store.remove(items, epoch, id, revision)

  defp take(items, epoch, id, revision, remainder) do
    with {:ok, next, _} <- Store.replace(items, epoch, id, revision, remainder),
         do: {:ok, next}
  end

  # The planning slot (`:plan` job): a worker plans a durable mutation from
  # values while the owner keeps answering; `pending` (with the caller) is
  # what adopting the result needs. One tick's phases may each want the slot
  # (a cross merge out, then the auto merge after the move): the later waits.
  defp start_plan(state, pending, from, work) do
    if planning?(state),
      do: {:reply, Error.retry(:item_storage_busy), state},
      else: start_plan!(state, pending, from, work)
  end

  defp start_plan!(state, pending, from, work) do
    case start_job(state, :plan, work,
           supervisor: Valimc.ItemWorkers,
           deadline: 5000,
           data: Map.put(pending, :from, from)
         ) do
      {:ok, state} -> {:noreply, state}
      {:error, _} -> {:reply, Error.retry(:item_workers_busy), state}
    end
  end

  @doc false
  def planning?(state), do: Jobs.running?(state.jobs, :plan)

  defp planning(state), do: with(%{data: pending} <- Jobs.get(state.jobs, :plan), do: pending)

  # Entity handoffs name their ends by section key (VMC-077j); the other plans
  # check positions against this section's coordinates.
  @handoff_plans [:item_handoff_in, :item_handoff_out, :item_merge_out, :item_handoff_clear]

  defp plan_item_change(kind, request, from, state) do
    items = state.entities.store
    key = if kind in @handoff_plans, do: route_key(state), else: state.key

    acceptance_deadline =
      case kind do
        :item_handoff_out -> elem(request, 2)
        :pickup_admission -> elem(request, 2)
        :item_merge_out -> elem(request, 3)
        :item_merge -> elem(request, 1)
        :item_merge_auto -> elem(request, 1)
        _ -> nil
      end

    start_plan(
      state,
      %{kind: kind, acceptance_deadline: acceptance_deadline},
      from,
      fn -> item_plan(kind, items, key, request) end
    )
  end

  defp item_plan(:item_handoff_in, items, key, transfer) do
    case Handoffs.accept(items, key, transfer) do
      {:ok, next, result} when result in [:applied, :rejected] ->
        {:write, next, {:ok, result}}

      {:ok, _, result} ->
        {:reply, {:ok, result}}

      error ->
        error
    end
  end

  defp item_plan(:item_handoff_out, items, key, {destination, steps, _}) do
    with {:ok, next, request} <-
           Handoffs.depart(items, key, items.epoch, destination, steps),
         do: {:write, next, {:ok, request.sequence}}
  end

  defp item_plan(:item_merge_out, items, key, {donor, destination, target, _}) do
    with {:ok, next, request} <-
           Handoffs.depart_merge(items, key, items.epoch, donor, destination, target),
         do: {:write, next, {:ok, request.sequence}}
  end

  defp item_plan(:item_handoff_clear, items, key, {sequence, digest, result}) do
    with {:ok, next} <- Handoffs.finish(items, key, sequence, digest, result),
         do: {:write, next, {:ok, result}}
  end

  defp item_plan(:item_merge, items, _key, {pairs, _deadline}), do: merge_plan(items, pairs)

  defp item_plan(:item_merge_auto, items, _key, _) do
    case ItemMerges.candidates(items) do
      [] -> {:reply, {:ok, []}}
      pairs -> merge_plan(items, pairs)
    end
  end

  defp merge_plan(items, pairs) do
    case ItemMerges.plan(items, items.epoch, pairs) do
      {:ok, ^items, changes} -> {:reply, {:ok, changes}}
      {:ok, next, changes} -> {:write, next, {:ok, changes}}
      error -> error
    end
  end

  defp container_metadata_affected?(containers, expected, edits) do
    Enum.any?(edits, fn {position, block} ->
      Map.has_key?(containers.entries, position) or Valimc.Blocks.block_entity(block) != nil or
        Valimc.Blocks.block_entity(expected[position]) != nil
    end)
  end

  defp start_container_blocks(state, from, batch, expected, reply \\ :revision) do
    containers = state.containers
    items = state.entities.store
    key = state.key

    pending = %{
      kind: :container_blocks,
      reply: reply,
      batch: batch
    }

    # A container's block change plans here, at once: a player's placement or
    # break is a plain call from its group (VMC-077i3) that cannot wait.
    result =
      with {:ok, change} <- ContainerLifecycle.plan(containers, key, expected, batch.edits),
           {:ok, next} <- ContainerSpills.add(items, key, change.removed),
           do: {:ok, Map.put(change, :items, next)}

    job_done(:plan, Map.put(pending, :from, from), result, state)
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
        Valimc.Blocks.BlockEntityTypes.unsupported?(block) and
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
        Valimc.Data.Metrics.add(:loot_unpacks)
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

      case Valimc.Menus.MenuAccess.authorize(
             :chest,
             block,
             provisional,
             above,
             position,
             grant,
             now
           ) do
        {:chest, _, _} -> unpack_loot(state, position, 0.0)
        _ -> state
      end
    else
      state
    end
  end

  defp unpack_to_open(state, _, _), do: state

  # A container set without its entry (`/setblock`, `/fill`, `/clone`, `/place`
  # without loot) gets an empty one when first used, as its block entity
  # exists in vanilla; loot still unpacks first.
  defp ensure_container(state, position) do
    with nil <- write_busy(state),
         block = Blocks.get(state.blocks, position),
         false <- LootChests.unrolled?(state.containers, state.block_entities, position, block),
         {:ok, containers} <-
           ContainerLifecycle.ensure(state.containers, state.key, position, block) do
      %{state | containers: containers}
    else
      _ -> state
    end
  end

  defp unpack_to_break(state, position, block) do
    if Valimc.Blocks.Chest.single?(Valimc.Blocks.after_removal(block)),
      do: state,
      else: unpack_loot(state, position, 0.0)
  end

  # An imported block entity holding data ValiMC cannot drop or spill keeps its
  # block (VMC-021e1).
  defp preserved_change?(state, changes),
    do: BlockEntities.protected?(state.block_entities, changes, &Blocks.get(state.blocks, &1))

  # Vanilla may consume a use of an imported block entity's block (signs, beds,
  # lecterns, double chests...); ValiMC cannot perform it, so it refuses rather
  # than placing against the block (VMC-021e1).
  defp preserved_use?(state, position, block),
    do:
      Valimc.Blocks.BlockEntityTypes.interactive?(block) and
        BlockEntities.live(state.block_entities, position, block) != nil

  # The update packet of a live imported block entity with an update tag, or nil.
  defp preserved_update(state, {x, _, z} = position) do
    with true <- Grid.region_key(Grid.chunk_key(x, z)) == state.key,
         %{type: type, update: update} when update != nil <-
           BlockEntities.live(state.block_entities, position, Blocks.get(state.blocks, position)) do
      Valimc.Blocks.ChestBlockEntity.data_packet(position, type, update)
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
      do: Error.retry(:chunk_generating),
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

          # Like an empty chest, an empty cooking block may be replaced by
          # another kind of block; its entry goes with it.
          block != original and
            not (Valimc.World.CookingEntry.empty?(entry) and
                   Valimc.Blocks.CookingBlocks.kind(original) == entry.kind and
                   Valimc.Blocks.CookingBlocks.kind(block) != entry.kind)

        %{slots: slots} = entry ->
          block != Blocks.get(state.blocks, position) and
            Enum.any?(Tuple.to_list(slots), &(&1 != nil)) and
            not (retired[position] == entry and
                   Valimc.Blocks.Chest.single?(Blocks.get(state.blocks, position)) and
                   not Valimc.Blocks.Chest.single?(block))

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

    state = %{
      state
      | containers: ContainerLifecycle.retire_replaced(state.containers, proposal.changes)
    }

    chunks =
      Enum.uniq(Enum.map(Map.keys(proposal.changes), fn {x, _, z} -> Grid.chunk_key(x, z) end))

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
    for chunk <- chunks, do: :ets.delete(state.publication, {:frame, chunk})
    %{state | cache: Map.drop(state.cache, chunks)}
  end

  defp release_blocks(state, effects) do
    state =
      if effects.cooking,
        do: state,
        else: retire_container_changes(state, effects.batch.edits, effects.previous)

    light = Valimc.World.LightHalo.frames(state, Map.get(effects, :light, []), :border)
    state = publish_block_snapshots(state, effects.chunks)

    # Clients relight from the light packets after the block updates; neighbours
    # relight their ring from the changed blocks.
    Valimc.World.publish(route_key(state), {:block_batch, effects.batch.frames ++ light})
    Valimc.World.LightHalo.forward(state, effects.batch.edits)
    Valimc.Data.Metrics.add(:block_edits, map_size(effects.batch.edits))
    state
  end

  # Readers see changed chunks as soon as the owner adopts them (D2), before
  # any client hears of the change: a client may act on an update at once, and
  # its moves are checked against these snapshots, not the owner's blocks.
  defp publish_block_snapshots(state, chunks) do
    :ok =
      BlockSnapshot.publish_chunks(state.publication, state.blocks, chunks, state.revision)

    state
  end

  defp isolated_chest_changes?(state, batch) do
    Enum.all?(batch.edits, fn {position, block} ->
      if Valimc.Blocks.Chest.single?(block) and
           not Valimc.Blocks.Chest.single?(Blocks.get(state.blocks, position)) do
        # The player's group decided the chest stays single
        # (`ChestPlacement.joins?/5`); only half of a double chest beside it
        # refuses. A neighbour across a section line is read in its sibling,
        # which the group holds; one outside the group refuses.
        Enum.all?(Valimc.Blocks.ChestPlacement.neighbors(position), fn {x, _, z} = neighbor ->
          neighbor_state =
            case Grid.region_key(Grid.chunk_key(x, z)) do
              key when key == state.key ->
                Map.get(batch.edits, neighbor, Blocks.get(state.blocks, neighbor))

              key ->
                with %{blocks: blocks} <- state.siblings[key], do: Blocks.get(blocks, neighbor)
            end

          neighbor_state != nil and
            not MapSet.member?(Valimc.Blocks.Chest.double_states(), neighbor_state)
        end)
      else
        true
      end
    end)
  end

  # A chunk's packet is encoded as job `{:encode, chunk}`; `encodes` holds the
  # callers waiting for it.
  defp start_encode(state, key) do
    if Jobs.running?(state.jobs, {:encode, key}) do
      state
    else
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

      work = fn ->
        started = System.monotonic_time(:microsecond)

        packet =
          if encoded == :flat,
            do: Chunk.encode(key, %{}, light),
            else: Chunk.packet(encoded, entities, preserved, light)

        frame = Packets.frame(packet, threshold)
        Valimc.Data.Metrics.add(:chunks_encoded)

        Valimc.Data.Metrics.add(
          :chunk_encode_microseconds,
          sections_microseconds + System.monotonic_time(:microsecond) - started
        )

        frame
      end

      case start_job(state, {:encode, key}, work,
             slots: :chunk_encode,
             data: %{version: version}
           ) do
        {:ok, state} ->
          state

        {:error, _} ->
          send_after(state, {:retry_encode, key}, 10)
          state
      end
    end
  end

  ## Jobs (VMC-077g): one report, deadline and failure path for every kind.

  def handle_info({:job, kind, token, result}, state) do
    case Jobs.finish(state.jobs, kind, token) do
      {:ok, job, jobs} -> job_done(kind, job.data, result, %{state | jobs: jobs})
      :stale -> {:noreply, state}
    end
  end

  def handle_info({:job_deadline, kind, token}, state) do
    case Jobs.expire(state.jobs, kind, token) do
      {:ok, job, jobs} -> job_failed(kind, job.data, :timeout, %{state | jobs: jobs})
      :stale -> {:noreply, state}
    end
  end

  # A worker's monitor (`Valimc.World.Jobs`): one that ended without a report.
  def handle_info({:job_down, ref, reason}, state) do
    case Jobs.down(state.jobs, ref, reason) do
      {:ok, job, jobs} -> job_failed(job.kind, job.data, {:down, reason}, %{state | jobs: jobs})
      :none -> {:noreply, state}
    end
  end

  def handle_info(
        {:item_handoff_wake, token},
        %{entities: %{handoff: %{phase: :retry, token: token}}} = state
      ) do
    case start_job(
           state,
           :handoff,
           EntityHandoffDelivery.work(route_key(state), state.entities.store.ledger),
           supervisor: Valimc.TransferWorkers,
           link: true,
           deadline: 8000
         ) do
      {:ok, state} ->
        {:noreply, %{state | entities: %{state.entities | handoff: %{phase: :delivering}}}}

      {:error, _} ->
        {:noreply, schedule_handoff_retry(state, 250)}
    end
  end

  def handle_info(
        {:item_handoff_wake, token},
        %{entities: %{handoff: %{phase: :ready_clear, token: token} = ack}} = state
      ) do
    if write_busy(state) != nil do
      {:noreply, schedule_handoff_clear(state, ack.receipt, 100)}
    else
      case plan_item_change(:item_handoff_clear, ack.receipt, nil, state) do
        {:noreply, next} ->
          {:noreply, %{next | entities: %{next.entities | handoff: %{phase: :clearing}}}}

        {:reply, _, next} ->
          {:noreply, schedule_handoff_clear(next, ack.receipt, 100)}
      end
    end
  end

  def handle_info({:halo, message}, state),
    do: {:noreply, Valimc.World.LightHalo.handle(message, state)}

  def handle_info({:item_handoff_wake, _}, state), do: {:noreply, state}

  def handle_info({:retry_encode, key}, state) do
    if Map.has_key?(state.encodes, key),
      do: {:noreply, start_encode(state, key)},
      else: {:noreply, state}
  end

  # Generation (VMC-075, VMC-077n): full chunks, failures, retries and wants.
  def handle_info({:generated, _scheduler, fulls}, state),
    do: {:noreply, RegionGeneration.received(state, fulls)}

  def handle_info({:generation_failed, chunks, reason}, state),
    do: {:noreply, RegionGeneration.generation_failed(state, chunks, reason)}

  def handle_info(:generation_retry, state), do: {:noreply, RegionGeneration.retry(state)}

  def handle_info({:ticket, holder, type, chunks}, state) do
    chunks = Enum.filter(chunks, &(Grid.region_key(&1) == state.key))
    tickets = Tickets.put(state.tickets, holder, type, chunks, state.game_tick)
    {:noreply, RegionGeneration.pump(%{state | tickets: tickets})}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    with :error <- Tickets.down(state.tickets, ref),
         :error <- RegionGeneration.down(state, ref) do
      viewer_down(state, ref, pid)
    else
      {:ok, %Tickets{} = tickets} -> {:noreply, %{state | tickets: tickets}}
      {:ok, state} -> {:noreply, state}
    end
  end

  def handle_info({:storage_durable, seq}, state), do: durable(state, seq)

  # A frame that may be torn: only the log's recovery and a reload continue.
  def handle_info({:storage_failed, _owner, _seq, reason}, state),
    do: {:stop, {:storage_failed, reason}, state}

  def handle_info({:checkpointed, ref, seq, result}, state),
    do:
      {:noreply, %{state | storage: RegionStorage.checkpointed(state.storage, ref, seq, result)}}

  # `/save-all`: a checkpoint once its frames are appended (`/save-off` pauses them).
  def handle_info({:save, :force}, state) do
    state = commit(%{state | storage: RegionStorage.request_checkpoint(state.storage)})
    {:noreply, maybe_checkpoint(state)}
  end

  # A bed or respawn anchor a player used went off (VMC-040a): sent by the
  # player's session to this section after its callback, so the group's
  # players (the user too) are hit through their sessions as by TNT.
  def handle_info({:explode, %Explosion{} = explosion}, state),
    do: {:noreply, explode(state, explosion)}

  def handle_info({:container_unsubscribe, connection, ref}, state) do
    {:noreply,
     apply_container_viewers(
       state,
       ContainerViewers.unregister(state.container_viewers, connection, ref)
     )}
  end

  def handle_info(_, state), do: {:noreply, state}

  # A block menu's grant (VMC-077i3): opening, checking or refreshing a
  # chest, furnace or crafting table, decided at once by a plain call from the
  # player's group (`MenuAccess`). Container views subscribe their connection
  # (`viewer`) to changes.
  # A player's use of a redstone component (VMC-047a, `useWithoutItem`): a
  # lever, button, note block, daylight detector, or a door, trapdoor or
  # fence gate a hand opens, in reach, with the hand that may use it; the
  # rules decide whether it is used (an iron door passes the use on to
  # placement). A spectator uses none; one in adventure mode may not invert
  # a detector.
  defp redstone_use(state, epoch, viewer, position, %{kind: :open} = grant) do
    now = System.monotonic_time(:millisecond)

    with true <- epoch == state.epoch and valid_block_query?([position], :any),
         true <- in_region?(state, position),
         block = Blocks.get(state.blocks, position),
         true <- Redstone.usable?(block),
         %{mode: mode, eye: eye, expires: expires, hand: hand} <- grant,
         true <-
           mode in [:survival, :creative, :adventure] and is_integer(expires) and now < expires,
         true <-
           Valimc.Living.Interaction.opens_block_menu?(
             mode,
             hand,
             grant[:secondary] == true,
             grant[:main] == true,
             grant[:off] == true
           ),
         true <- Valimc.Living.Interaction.within_block?(mode, eye, position),
         nil <- write_busy(state) do
      facing = Enum.at([3, 4, 2, 5], Bitwise.band(floor((grant[:yaw] || 0.0) / 90.0 + 0.5), 3))
      action = {:use, position, facing, mode != :adventure}

      case rule_run(state, %{actions: [action], actor: viewer}) do
        {state, %{results: [1]}} -> {:used, state}
        _ -> :pass
      end
    else
      _ -> :pass
    end
  end

  defp redstone_use(_state, _epoch, _viewer, _position, _grant), do: :pass

  defp menu_request(state, epoch, viewer, position, grant) do
    state =
      if epoch == state.epoch and valid_block_query?([position], :any) and
           in_region?(state, position),
         do: state |> unpack_to_open(position, grant) |> ensure_container(position),
         else: state

    decision =
      cond do
        epoch != state.epoch ->
          Error.retry(:stale_owner)

        not valid_block_query?([position], :any) ->
          {:error, :invalid_block_query}

        Grid.region_key(Grid.chunk_key(elem(position, 0), elem(position, 2))) !=
            state.key ->
          {:error, :wrong_region}

        true ->
          block = Blocks.get(state.blocks, position)
          now = System.monotonic_time(:millisecond)

          cond do
            Valimc.Blocks.CookingBlocks.kind(block) != nil or
                (is_map(grant) and grant[:menu] == :cooking) ->
              Valimc.Menus.MenuAccess.authorize(
                :cooking,
                block,
                state.containers.entries[position],
                nil,
                position,
                grant,
                now
              )

            Valimc.Blocks.Chest.single?(block) or (is_map(grant) and grant[:menu] == :chest) ->
              {x, y, z} = position

              Valimc.Menus.MenuAccess.authorize(
                :chest,
                block,
                state.containers.entries[position],
                Blocks.get(state.blocks, {x, y + 1, z}),
                position,
                grant,
                now
              )

            preserved_use?(state, position, block) ->
              Valimc.Menus.MenuAccess.refuse_use(block, position, grant, now)

            true ->
              Valimc.Menus.MenuAccess.authorize(:table, block, nil, nil, position, grant, now)
          end
      end

    container_view_decision(state, viewer, position, grant, decision)
  end

  # A container viewer went down.
  defp viewer_down(state, ref, pid),
    do:
      {:noreply,
       apply_container_viewers(state, ContainerViewers.down(state.container_viewers, pid, ref))}

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
              Valimc.Player.PlayerList.deliver(
                pid,
                {:container_changed, {self(), state.epoch}, ref, position, revision}
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
          Valimc.Player.PlayerList.deliver(
            view.pid,
            {:container_closed, {self(), state.epoch}, view.ref}
          )

    apply_container_viewers(state, {viewers, retired, lids}, false)
  end

  defp apply_container_viewers(state, {viewers, retired, lids}, sound? \\ true) do
    for view <- retired, do: Process.demonitor(view.monitor, [:flush])
    state = %{state | container_viewers: viewers}
    threshold = Valimc.config(:compression_threshold)

    for chunk <-
          lids
          |> Enum.map(fn {{x, _, z}, _} -> Grid.chunk_key(x, z) end)
          |> Enum.uniq() do
      positions =
        for {{x, _, z} = position, {_, count}} <- viewers.positions,
            count > 0 and Grid.chunk_key(x, z) == chunk,
            do: position

      positions = Enum.sort(positions)

      if positions == [] do
        :ets.delete(state.publication, {:container_lids, chunk})
      else
        frame =
          positions
          |> Enum.map(&Packets.frame(Packets.chest_lid(&1, true), threshold))
          |> IO.iodata_to_binary()

        :ets.insert(
          state.publication,
          {{:container_lids, chunk}, state.epoch, positions, frame}
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
        route_key(state),
        {:chest_lid, {self(), state.epoch}, position, open, frame, sound}
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
    do:
      Grid.region_key(Grid.chunk_key(x, z)) == state.key and
        Chunk.valid_y?(y)

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
    do: Process.send_after(self(), {:resource, state.epoch, message}, delay)

  # Writes are acknowledged in queue order (the writer is FIFO). Release the
  # head write's effects, then everything that waited on it.
  defp reply_item(nil, _), do: :ok
  defp reply_item({:deliver, pid}, message), do: Valimc.Player.PlayerList.deliver(pid, message)
  defp reply_item(from, reply), do: GenServer.reply(from, reply)

  defp finish_item_reply(state, from, reply) do
    reply_item(from, reply)
    state
  end

  defp commit_simulated_items(state, steps) do
    steps =
      Enum.flat_map(steps, fn step ->
        case state.entities.store.entries[step.id] do
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

    route = route_key(state)

    # Items and orbs that burned up (VMC-034n4d) go at once, wherever their
    # step led; the next frame drops their records.
    {dead, steps} = Enum.split_with(steps, &Map.get(&1, :dead, false))

    {local, borders} =
      Enum.split_with(steps, fn %{position: {x, _, z}} ->
        Grid.section(state.dimension, Grid.chunk_key(x, z)) == route
      end)

    # Items and orbs travel through portals.
    {local, state} = portal_contacts(state, local)

    # Motion waits while a plan holds the store; the tick's end publishes it.
    state =
      if write_busy(state) != nil do
        state
      else
        state = burn_up(state, dead)

        Enum.reduce(Enum.chunk_every(local, 32), state, fn batch, acc ->
          case Store.advance(acc.entities.store, acc.key, acc.epoch, batch) do
            {:ok, items, _} -> %{acc | entities: %{acc.entities | store: items}}
            {:error, _} -> acc
          end
        end)
      end

    {nearby, away} =
      borders
      |> Enum.group_by(fn %{position: {x, _, z}} ->
        Grid.section(state.dimension, Grid.chunk_key(x, z))
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.split_with(fn {destination, _} -> local_destination?(state, destination) end)

    state =
      for {destination, batch} <- nearby, chunk <- Enum.chunk_every(batch, 32), reduce: state do
        acc -> move_to_sibling(acc, destination, chunk)
      end

    if away != [] and state.entities.store.ledger.outgoing == nil and state.entities.persistent do
      [{destination, batch} | _] = away

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

  defp burn_up(state, []), do: state

  defp burn_up(state, dead) do
    store =
      Enum.reduce(dead, state.entities.store, fn step, acc ->
        case Store.remove(acc, acc.epoch, step.id, step.revision) do
          {:ok, next} -> next
          _ -> acc
        end
      end)

    publish_item_views(%{state | entities: %{state.entities | store: store}})
  end

  # Entities in portals (VMC-026c, VMC-026d): steps meeting a portal renew
  # their cooldown; one off cooldown starts this owner's single destination job.
  defp portal_contacts(state, local) do
    read = fn cells ->
      Blocks.get_many(state.blocks, Enum.filter(cells, &in_region?(state, &1)))
    end

    free = state.entities.portal == nil and not Jobs.running?(state.jobs, :portal)

    case EntityPortals.contacts(local, state.entities.store.entries, read, free) do
      {local, nil} ->
        {local, state}

      {local, {step, entry, _} = travel} ->
        case start_job(state, :portal, EntityPortals.work(travel),
               supervisor: Valimc.TransferWorkers,
               deadline: EntityPortals.deadline(),
               data: %{uuid: entry.entity.uuid}
             ) do
          {:ok, state} ->
            local = Enum.map(local, &if(&1.id == step.id, do: EntityPortals.renew(&1), else: &1))
            {local, state}

          {:error, _} ->
            {local, state}
        end
    end
  end

  # A travelled entity (its destination found) moves once this owner's item
  # plans and outgoing intent are free.
  defp travel_item(
         %{entities: %{portal: %{target: target, uuid: uuid}}, jobs: %{entries: entries}} = state
       )
       when not is_map_key(entries, :plan) and state.entities.store.ledger.outgoing == nil and
              state.entities.persistent do
    state = %{state | entities: %{state.entities | portal: nil}}
    deadline = System.monotonic_time(:millisecond) + 250

    case EntityPortals.arrival(state.entities.store, route_key(state), uuid, target) do
      :gone ->
        state

      {:local, step} ->
        {:reply, _, next} =
          handle_call({:publish_item_motion, state.epoch, [step], deadline}, nil, state)

        next

      {:handoff, destination, step} ->
        if local_destination?(state, destination) do
          move_to_sibling(state, destination, [step])
        else
          case plan_item_change(:item_handoff_out, {destination, [step], deadline}, nil, state) do
            {:noreply, next} -> next
            {:reply, _, next} -> next
          end
        end
    end
  end

  defp travel_item(state), do: state

  # A handoff leaves only once its outgoing ledger record is durable: callers
  # reach this through `resume_handoff/1`, except at load.
  defp resume_handoff(state),
    do: {:effect, {:resume_item_handoff, state.entities.store.ledger.outgoing}}

  defp resume_item_handoff(%{entities: %{store: %{ledger: %{outgoing: nil}}}} = state),
    do: %{state | entities: %{state.entities | handoff: nil}}

  defp resume_item_handoff(%{entities: %{handoff: nil}} = state),
    do: schedule_handoff_retry(state, 0)

  defp resume_item_handoff(state), do: state

  defp schedule_handoff_retry(state, delay) do
    token = make_ref()
    timer = send_after(state, {:item_handoff_wake, token}, delay)
    %{state | entities: %{state.entities | handoff: %{phase: :retry, token: token, timer: timer}}}
  end

  # `receipt` is the destination's `{sequence, digest, result}`.
  defp schedule_handoff_clear(state, receipt, delay) do
    token = make_ref()
    timer = send_after(state, {:item_handoff_wake, token}, delay)
    handoff = %{phase: :ready_clear, receipt: receipt, token: token, timer: timer}
    %{state | entities: %{state.entities | handoff: handoff}}
  end

  defp item_plan_failed(state, pending) do
    state =
      if Map.get(pending, :kind) == :item_merge_auto,
        do: %{state | entities: %{state.entities | merge_stamp: nil}},
        else: state

    state =
      if Map.get(pending, :kind) == :item_handoff_clear,
        do: %{state | entities: %{state.entities | handoff: nil}},
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

  # Work that an unload would cut short: queued or planned writes, jobs,
  # generation, waiting calls, open containers and box edit locks.
  # A job's result (`Valimc.World.Jobs`), by kind.
  defp job_done(:cooking, job, {:ok, plan}, state),
    do: {:noreply, accept_cooking_plan(state, job, plan)}

  defp job_done(:cooking, _job, {:error, _}, state) do
    Valimc.Data.Metrics.add(:cooking_plan_failures)
    {:noreply, retry_cooking(state, 1000)}
  end

  # A crater job ended (VMC-050a): the next waiting craters start.
  defp job_done(:explosion, _job, _result, state), do: {:noreply, start_craters(state)}

  defp job_done(:portal, job, {:ok, target}, state),
    do:
      {:noreply,
       travel_item(%{
         state
         | entities: %{state.entities | portal: %{target: target, uuid: job.uuid}}
       })}

  defp job_done(:portal, _job, other, state) do
    require Logger
    Logger.warning("Item portal destination unavailable: #{inspect(other, limit: 12)}")
    {:noreply, state}
  end

  # A planned durable mutation, by what it plans.
  defp job_done(:plan, %{kind: :container_blocks} = pending, result, state) do
    with {:ok, %{containers: containers, removed: removed, items: items}} <- result,
         {:ok, proposal} <- block_proposal(state, pending.batch, removed) do
      # The contents drop in this region: nothing another owner acts on.
      state = publish_blocks(state, pending.batch, proposal)
      state = %{state | containers: containers}
      reply = if pending.reply == :ok, do: :ok, else: {:ok, state.revision}
      commit_items(items, reply, pending.from, state)
    else
      {:error, _} = error ->
        GenServer.reply(pending.from, error)
        {:noreply, item_plan_failed(state, pending)}
    end
  end

  defp job_done(:plan, pending, result, state) do
    result =
      if pending.acceptance_deadline != nil and
           System.monotonic_time(:millisecond) >= pending.acceptance_deadline,
         do: {:error, :expired_item_step},
         else: result

    case result do
      {:write, items, reply} ->
        state = %{state | entities: %{state.entities | store: items}}
        # A cleared handoff is over once adopted; the next one starts from its
        # resume. A rejected merge's donor is back: it waits before trying again.
        state =
          case {pending.kind, reply} do
            {:item_handoff_clear, {:ok, :rejected}} ->
              next = System.monotonic_time(:millisecond) + 1000
              %{state | entities: %{state.entities | handoff: nil, cross_next: next}}

            {:item_handoff_clear, _} ->
              %{state | entities: %{state.entities | handoff: nil}}

            _ ->
              state
          end

        state = publish_item_views(state)
        {:noreply, wait_durable(state, [{:reply, pending.from, reply}, resume_handoff(state)])}

      {:reply, reply} ->
        {:noreply, wait_durable(state, [{:reply, pending.from, reply}, resume_handoff(state)])}

      {:error, _} = error ->
        reply_item(pending.from, error)
        {:noreply, item_plan_failed(state, pending)}
    end
  end

  defp job_done({:encode, key}, job, frame, state) do
    if job.version == Map.get(state.versions, key, 0) do
      {waiters, encodes} = Map.pop(state.encodes, key, [])
      for from <- waiters, do: GenServer.reply(from, frame)
      # Connections read a published frame without asking (VMC-077e).
      :ets.insert(state.publication, {{:frame, key}, frame})
      {:noreply, %{state | encodes: encodes, cache: Map.put(state.cache, key, frame)}}
    else
      Valimc.Data.Metrics.add(:stale_chunk_results_discarded)
      {:noreply, start_encode(state, key)}
    end
  end

  defp job_done(:handoff, _job, {:ok, sequence, digest, result}, state),
    do: {:noreply, schedule_handoff_clear(state, {sequence, digest, result}, 0)}

  defp job_done(:handoff, _job, {:error, _}, state) do
    Valimc.Data.Metrics.add(:item_handoff_retries)
    {:noreply, schedule_handoff_retry(state, 250)}
  end

  # A job that overran its deadline (`:timeout`, killed) or died (`{:down, reason}`).
  defp job_failed({:encode, key}, _job, reason, state) do
    {waiters, encodes} = Map.pop(state.encodes, key, [])
    for from <- waiters, do: GenServer.reply(from, {:error, {:encoder_failed, reason}})
    {:noreply, %{state | encodes: encodes}}
  end

  defp job_failed(:handoff, _job, _reason, state) do
    Valimc.Data.Metrics.add(:item_handoff_retries)
    {:noreply, schedule_handoff_retry(state, 250)}
  end

  # A plan has adopted nothing yet: its caller may retry.
  defp job_failed(:plan, pending, _reason, state) do
    reply_item(pending.from, Error.retry(:item_plan_failed))
    {:noreply, item_plan_failed(state, pending)}
  end

  defp job_failed(:explosion, _job, reason, state) do
    require Logger
    Logger.warning("Explosion craters failed: #{inspect(reason, limit: 12)}")
    {:noreply, start_craters(state)}
  end

  defp job_failed(:portal, _job, reason, state) do
    require Logger
    Logger.warning("Item portal destination failed: #{inspect(reason, limit: 12)}")
    {:noreply, state}
  end

  defp job_failed(:cooking, _job, reason, state) do
    Valimc.Data.Metrics.add(
      if reason == :timeout, do: :cooking_timeouts, else: :cooking_plan_failures
    )

    {:noreply, retry_cooking(state, 100)}
  end

  defp retry_cooking(state, ms) do
    retry_at = System.monotonic_time(:millisecond) + ms
    %{state | cooking: %{state.cooking | seen: nil, retry_at: retry_at}}
  end

  defp busy?(state) do
    RegionStorage.busy?(state.storage) or Jobs.busy?(state.jobs) or
      state.entities.handoff != nil or state.entities.portal != nil or
      map_size(state.encodes) > 0 or
      RegionGeneration.busy?(state.generation) or
      map_size(state.container_viewers.views) > 0 or map_size(state.permits.entries) > 0
  end

  def terminate(reason, state) do
    if pending = planning(state), do: reply_item(pending.from, Error.retry(:item_plan_failed))
    Jobs.stop_all(state.jobs)

    # A clean stop (unload, shutdown) cuts the last frame, waits for it and
    # leaves a checkpoint, so nothing of the region stays in the log. Replies
    # still waiting on a frame (a failed one, or any after a crash) learn its
    # outcome is uncertain; a retry resolves it.
    state =
      if reason in [:normal, :shutdown] or match?({:shutdown, _}, reason),
        do: save_now(state, detach: reason == :normal),
        else: state

    for {:reply, from, _} <-
          state.storage.waits ++ Enum.flat_map(Map.values(state.storage.in_flight), & &1),
        not match?({:deliver, _}, from),
        do: reply_item(from, Error.retry(:item_commit_uncertain))

    :ok
  end
end
