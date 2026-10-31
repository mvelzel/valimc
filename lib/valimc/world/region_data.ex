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
    Containers,
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
  alias Valimc.Entity.{EffectCloud, NativeBody, Projectile}
  alias Valimc.Native
  alias Valimc.World.Projectiles
  alias Valimc.World.ContainerSpills

  alias Valimc.Data.Error
  alias Valimc.Menus.Inventory
  alias Valimc.Protocol.Packets
  alias Valimc.Txn.Permits
  alias Valimc.World.BlockRules
  alias Valimc.Blocks.Redstone
  import Bitwise, only: [|||: 2, <<<: 2]

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
    {:light_pending, %{}},
    {:light_retry, false},
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
    # Only the End origin section owns the durable fight; the bar and
    # generated spike descriptions are transient and move with that section.
    {:arena, nil},
    {:arena_view, nil},
    {:arena_spikes, []},
    {:arena_pillars, nil},
    {:arena_retry, 0},
    # The group's other sections (VMC-077j), as the group hands them in
    # (`Region`): what the block rules read across and whether a plan holds
    # each; and what this section's call did to them (block-rule changes,
    # entities moved there), which the group applies once the call returns.
    {:siblings, %{}},
    # The group's sections whose stores hold a leash knot, as the group
    # hands them in (VMC-081j); nil outside a group's call.
    {:knotted, nil},
    {:sibling_effects, []},
    # The group's native mob world (VMC-081d, `Native.mob_world_set/2`): its
    # level, players and sections, as the group hands it in.
    {:mob_world, nil},
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
    # What players did that this section's mobs react to before they next
    # think (VMC-043d, the tick's `events`): at most 64.
    {:mob_events, []},
    # The POI tickets this section's villagers hold (VMC-044a1), for its siblings.
    {:poi_claims, %{}},
    # One completed structure search, consumed at the next accepted mob tick.
    {:mob_located, nil},
    # Merchants whose offers wait for an exploration map's structure search
    # (VMC-044b2): `[%{uuid, merchant, answers, append}]`, at most 64, the
    # first searching.
    {:trade_waiting, []},
    # Explosions whose craters wait for the crater job (VMC-050a):
    # `[{explosion, cells}]`, at most 64.
    {:explosions, []},
    # Redstone torches' recent toggles (VMC-047a, `RECENT_TOGGLES`, which
    # vanilla keeps per level in memory): `[{position, game tick}]`.
    {:torch_toggles, []},
    # Comparators' outputs (VMC-048a, their block entities'): `position =>
    # output`, persisted; the block rules keep it.
    {:comparators, %{}},
    # Moving pistons' block entities (VMC-048b): `position => {moved,
    # direction, extending?, source?, progress, progress_o, last_ticked,
    # order}`, persisted, and in the section's store beside the cells; the
    # order they tick in counts on from `piston_order`.
    {:pistons, %{}},
    {:piston_order, 0},
    # Block events raised and not yet run (`ServerLevel.blockEvents`, as
    # vanilla keeps them in memory): `[{position, block, b0, b1}]`.
    {:block_events, []},
    # When each hopper last ticked (VMC-049a, `tickedGameTime`, which vanilla
    # keeps in memory): `position => game tick`.
    {:hopper_ticked, %{}},
    # Dispensers and droppers that fired while a plan held the item store
    # (VMC-049a): they dispense at the next block phase.
    {:dispense_backlog, []},
    # The containers as comparators last heard of them: a change of a
    # container's signal reaches them at the next block phase.
    :containers_seen,
    # Native mobs an outgoing handoff carries (VMC-081d): their section keeps
    # their state before the tick until the handoff's plan ends.
    {:native_departing, []},
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

    # The section's native mobs (VMC-081d) live in Rust beside its blocks.
    native = Valimc.Entity.NativeMobs.new(key)

    items =
      case Store.restore(key, loaded.items, loaded.ledger, native) do
        {:ok, items} -> items
        {:error, reason} -> exit({:item_load_failed, reason})
      end

    tick_index = TickBehaviours.index(TickBehaviours.modules(key))
    # Moving pistons' block entities go beside their cells before any snapshot.
    Blocks.put_pistons(blocks, loaded.pistons)

    # Random draws of lava and growing plants run in the block rules, those
    # of the behaviours' states here (VMC-081g1).
    :ok =
      Blocks.random_ticking(
        blocks,
        Enum.to_list(Valimc.Data.Blocks.states("lava")) ++ Valimc.World.Growth.states(),
        for({state, module} <- tick_index, function_exported?(module, :random_tick, 4), do: state)
      )

    # Entities' redstone contacts and mobs' portal sweeps run only where
    # their blocks are (VMC-081j).
    :ok =
      Blocks.counted_states(
        blocks,
        Redstone.contact_states(),
        Enum.flat_map(
          ~w(nether_portal end_portal end_gateway),
          &Enum.to_list(Valimc.Data.Blocks.states(&1))
        )
      )

    publication = :ets.new(:region_publication, [:set, :protected, read_concurrency: true])
    :ok = Publication.init(publication, items.epoch)
    # Every generated chunk has a row, with its heightmaps and biomes (VMC-077e).
    present =
      for chunk <- RegionGeneration.chunks_of(key),
          not RegionGeneration.absent?(generation, chunk),
          do: chunk

    :ok = BlockSnapshot.publish_chunks(publication, blocks, present, 0)
    :ok = BlockSnapshot.publish_absent(publication, MapSet.to_list(generation.absent))

    arena =
      if dimension == :the_end and key == {0, 0} do
        seed = Valimc.World.Spec.fetch(Valimc.config(:world_path, key)).seed

        {loaded.arena || Valimc.World.Dragon.Arena.new(dimension, key, seed),
         Valimc.World.Dragon.Fight.spikes(seed)}
      else
        {nil, []}
      end

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
      pistons: loaded.pistons,
      piston_order: next_piston_order(loaded.pistons),
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
      arena: elem(arena, 0),
      arena_spikes: elem(arena, 1),
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
      pistons: state.pistons,
      post: state.post,
      structures: state.structures,
      arena: state.arena,
      game_tick: state.game_tick
    }

  defp baseline_storage(state) do
    {parts, state} = take_parts(state)
    %{state | storage: RegionStorage.baseline(state.storage, parts)}
  end

  # The parts with their journals (`Store` and `ScheduledTicks`'s `dirty`),
  # and the state without them: the storage that takes them writes what
  # they name (VMC-081h).
  defp take_parts(state) do
    parts = parts(state)
    {_, store} = Store.take_dirty(state.entities.store)
    {_, ticks} = ScheduledTicks.take_dirty(state.scheduled_ticks)

    {parts, %{state | entities: %{state.entities | store: store}, scheduled_ticks: ticks}}
  end

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
        do: state |> simulate_items(now) |> drop_deaths() |> redstone_contacts(),
        else: state

    track_entities(state)
  end

  @doc """
  Whether the entity phase (`item_tick/2`) would change nothing: the section
  simulates nothing, no drop or portal arrival waits, and its tracking is
  idle over the very terms it last passed (`Tracking.same/3`).
  """
  def entities_idle?(state) do
    store = state.entities.store
    tracking = state.entities.tracking

    not Tickets.simulating?(state.tickets) and state.entities.dropped == [] and
      state.entities.portal == nil and
      Tracking.same(tracking, store.views, state.player_views) == :same and
      Tracking.idle?(
        tracking,
        store.views,
        {state.player_views, state.player_frame},
        MapSet.new()
      )
  end

  defp simulate_items(state, now) do
    # A planning worker's result replaces the item map, so ageing waits while one
    # runs; the skipped ticks are owed and applied at once, so despawn timing
    # never stalls.
    # Without debts (most ticks) every simulated chunk owes this tick alone.
    {owed, ready} =
      if state.entities.age_debt == %{} do
        ready = Map.new(state.tickets.simulated, &{&1, 1})
        {ready, ready}
      else
        owed =
          Enum.reduce(state.tickets.simulated, state.entities.age_debt, fn chunk, debt ->
            Map.update(debt, chunk, 1, &min(&1 + 1, 6000))
          end)

        {owed, Map.take(owed, MapSet.to_list(state.tickets.simulated))}
      end

    {items, expired} =
      if state.entities.simulate and not planning?(state),
        do:
          Store.age_chunks(
            wake_resting(state),
            ready,
            elem(Valimc.World.Dimension.bounds(state.dimension), 0),
            state.game_tick
          ),
        else: {nil, []}

    if items != nil and (expired == [] or write_busy(state) == nil) do
      debt = if owed === ready, do: %{}, else: Map.drop(owed, Map.keys(ready))

      state =
        remember_item_counters(%{state | entities: %{state.entities | age_debt: debt}}, items)

      if expired == [] do
        state
        |> tick_block_bodies()
        |> tick_crystals()
        |> tick_projectiles()
        |> tick_knots()
        |> start_item_cross_merging(now)
        |> move_mobs()
        |> move_items(now)
      else
        # A dead cube splits as it is removed (VMC-043d, `AbstractCubeMob.remove`).
        splits =
          for {_epoch, id, _revision} <- expired,
              entry <- [items.entries[id]],
              split <- cube_split(id, entry),
              do: split

        # What their effects do as they go (VMC-037p, `triggerOnDeathMobEffects`).
        removals =
          for {_epoch, id, _revision} <- expired, r <- removed(id, items.entries[id]), do: r

        items =
          Enum.reduce(expired, items, fn {epoch, id, revision}, acc ->
            {:ok, next} = Store.remove(acc, epoch, id, revision)
            next
          end)

        {:noreply, state} = commit_items(items, :ok, nil, state)

        state =
          Enum.reduce(splits, state, fn
            {%Body{} = body, position}, state ->
              create_body(state, Store.body_record(body, :crypto.strong_rand_bytes(16), position))

            {record, _position}, state ->
              create_body(state, %{record | uuid: :crypto.strong_rand_bytes(16)})
          end)

        Enum.reduce(removals, state, fn {at, height, actions}, state ->
          removal_effects(state, at, height, actions)
        end)
      end
    else
      if state.entities.simulate,
        do: %{state | entities: %{state.entities | age_debt: owed}},
        else: state
    end
  end

  # Resting items wake when their tick may change something again: a chunk
  # it reads was published anew, or the world border changed (VMC-081l).
  # Changes published during this tick before the items phase wake them for
  # it, as every tick's steps read the publications as they are.
  defp wake_resting(state) do
    Store.wake_stale(
      state.entities.store,
      Valimc.World.Clock.border_snapshot(),
      &chunk_publication(state, &1)
    )
  end

  defp chunk_publication(state, chunk) do
    case :ets.lookup(state.publication, {:chunk, chunk}) do
      [{_, handle}] -> handle
      [] -> nil
    end
  end

  # The items of a phase's local steps that `Store.advance/4` left unchanged
  # rest (VMC-081l): their next tick, over the same publications and border,
  # is the same as this one, but for their age. An item rests only where
  # what its tick reads (its cell two blocks around) is in this section's
  # chunks, with no pickup delay (or an unlimited one), no portal cooldown
  # and not burning, so only its age moves while it rests.
  defp rest_unchanged(state, store, batch, handles) do
    Enum.zip(batch, handles)
    |> Enum.reduce(store, fn {step, {_, id, revision}}, acc ->
      with true <- revision == step.revision,
           %{kind: :item, motion: motion, entity: %{x: x, z: z}} = entry <- acc.entries[id],
           true <- motion.pickup_delay in [0, 32_767] and motion.portal_cooldown == 0,
           true <- entry[:on_fire] != true and motion.fire_ticks <= 0,
           chunks =
             Enum.uniq(for dx <- [-2, 2], dz <- [-2, 2], do: Grid.chunk_key(x + dx, z + dz)),
           true <- Enum.all?(chunks, &(Grid.region_key(&1) == state.key)),
           deps = Enum.map(chunks, &{&1, chunk_publication(state, &1)}),
           true <- Enum.all?(deps, fn {_, handle} -> handle not in [nil, :absent] end) do
        Store.rest(acc, id, deps, state.game_tick)
      else
        _ -> acc
      end
    end)
  end

  def cooking_tick(%{cooking: runtime} = state, now) do
    cond do
      not runtime.enabled or not state.entities.persistent or
        Jobs.running?(state.jobs, :cooking) or write_busy(state) != nil ->
        state

      is_integer(runtime.retry_at) and now < runtime.retry_at and runtime.seen == nil ->
        state

      CookingRuntime.due?(
        runtime,
        state.containers,
        state.revision,
        state.entities.store,
        now,
        state.tickets.simulated
      ) ->
        start_cooking_plan(state, now)

      true ->
        state
    end
  end

  defp start_cooking_plan(state, now) do
    containers = state.containers
    items = state.entities.store
    chunks = state.tickets.simulated

    selection =
      CookingRuntime.selection(state.cooking, containers, state.revision, items, now, chunks)

    if selection == MapSet.new() do
      %{
        state
        | cooking: CookingRuntime.observed(state.cooking, containers, state.revision, chunks)
      }
    else
      start_selected_cooking(state, containers, items, selection, chunks, now)
    end
  end

  defp start_selected_cooking(state, containers, items, selection, chunks, now) do
    # Workers get values under selected processors, never the storage handle.
    edits = Blocks.get_many(state.blocks, MapSet.to_list(selection))
    key = state.key
    blocked = state.cooking.blocked

    case start_job(
           state,
           :cooking,
           fn -> CookingRuntime.plan(containers, items, key, edits, selection, blocked) end,
           supervisor: Valimc.ItemWorkers,
           deadline: 500,
           data: %{containers: containers, items: items, simulated: chunks}
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
        Enum.all?(plan.expected, fn {position, _} ->
          CookingRuntime.eligible?(position, state.tickets.simulated)
        end) and
        Enum.all?(plan.expected, fn {position, block} ->
          Blocks.get(state.blocks, position) == block
        end)

    with true <- current,
         {:ok, items} <- Store.merge_created(state.entities.store, job.items, plan.items) do
      plan = Map.put(%{plan | items: items}, :simulated, job.simulated)

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
        now,
        plan.simulated
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

  # Which items merge depends only on which items there are, where they
  # stand, their stacks and whether they may merge: the spatial index counts
  # those changes (`Spatial`'s `items`), so a plan starts only after one, and
  # an item's velocity or counters alone start none (VMC-081l).
  defp start_item_merging(state, now) do
    store = state.entities.store

    # Only items merge: other kinds neither start nor restart a merge plan.
    if state.entities.persistent and
         (state.entities.merge_next == nil or now >= state.entities.merge_next) and
         Valimc.Entity.Spatial.item_count(store.spatial) >= 2 do
      stamp = {store.epoch, store.spatial.items}

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
    # The simulated chunks' objects by the spatial index, in id order (as a
    # small store's map walk gave them), not every entity (VMC-081l).
    bodies =
      for {id, %{body: %{type: type}} = entry} <-
            Enum.sort(Store.in_chunks(state.entities.store, state.tickets.simulated, :object)),
          BlockBodies.ticks?(type),
          not Store.simulated?(entry, state.game_tick),
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

  # Crystals in a dimension with a dragon fight keep fire at their feet.
  defp tick_crystals(state) do
    if Valimc.World.Dimension.facts(state.dimension).dragon_fight and write_busy(state) == nil do
      Enum.reduce(state.entities.store.entries, state, fn
        {_, %{body: %{type: "minecraft:end_crystal"}, entity: e}}, acc ->
          cell = {floor(e.x), floor(e.y), floor(e.z)}
          below = {floor(e.x), floor(e.y) - 1, floor(e.z)}

          if Tickets.simulated?(acc.tickets, Grid.chunk_key(e.x, e.z)) and
               Valimc.World.Dimension.in_height?(elem(cell, 1), acc.dimension) and
               Valimc.Data.BlockFacts.air?(Blocks.get(acc.blocks, cell)),
             do:
               commit_landings(
                 acc,
                 %{cell => Explosion.fire_state(Blocks.get(acc.blocks, below))},
                 []
               ),
             else: acc

        _, acc ->
          acc
      end)
    else
      state
    end
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
    moved = for {:moved, id, _, _, _} <- steps, do: id
    state = put_entities(state, Store.mark_simulated(acc.store, moved, state.game_tick))

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
          Map.get(entry.body.data, :world_tick) != state.game_tick,
          not Store.simulated?(entry, state.game_tick),
          Tickets.simulated?(state.tickets, Grid.chunk_key(x, z)),
          reduce: {[], []} do
        {p, c} ->
          if type == EffectCloud.type(), do: {p, [{id, entry} | c]}, else: {[{id, entry} | p], c}
      end

    if (projectiles == [] and clouds == []) or write_busy(state) != nil or
         Enum.any?(state.siblings, fn {key, peer} -> key != state.key and peer.busy end) do
      state
    else
      targets = projectile_targets(state)
      part_targets = projectile_targets(state, true)
      living = living_targets(targets)
      state = Enum.reduce(Enum.sort(clouds), state, &tick_cloud(&2, &1, living))

      steps =
        Projectiles.step(
          Enum.sort(projectiles),
          part_targets,
          Clock.border_snapshot(),
          state.dimension == :the_nether
        )

      {difficulty, _} = Clock.difficulty()

      context = %{
        mob_griefing: Valimc.World.GameRules.get(:mob_griefing),
        difficulty: elem({:peaceful, :easy, :normal, :hard}, difficulty.level),
        targets: living,
        read: &read_block(state, &1)
      }

      by_id = Map.new(part_targets, &{&1.id, &1})

      {state, moves} =
        Enum.reduce(steps, {state, []}, fn {id, entry, result}, {acc, moves} ->
          run_projectile(acc, id, entry, Projectiles.plan(entry, result, by_id, context), moves)
        end)

      moved =
        for {id, _, result} <- steps,
            match?({:ok, _, _, _, _}, result) or match?({:returning, _, _}, result),
            do: id

      state =
        put_in(
          state.entities.store,
          Store.mark_simulated(state.entities.store, moved, state.game_tick)
        )

      route_bodies(state, Enum.reverse(moves))
    end
  end

  # What projectiles may hit: the owning group's living mobs, crystals and
  # players, `%{id, ref, uuid, type, position, box}`.
  defp projectile_targets(state, multipart \\ false) do
    mobs =
      for {sid, %{body: %{type: type} = body, entity: e}} <-
            group_entries(state),
          # A native mob's row (VMC-081d) is a living body's.
          match?(%Valimc.Entity.NativeBody{}, body) or
            (match?(%Body{}, body) and (body.mob != nil or type == "minecraft:end_crystal")),
          Body.alive?(body) do
        position = {e.x * 1.0, e.y * 1.0, e.z * 1.0}

        target = %{
          id: e.entity_id,
          ref: {:mob, sid},
          uuid: e.uuid,
          type: type,
          position: position,
          box: Body.box(body, position)
        }

        if multipart and type == "minecraft:ender_dragon" do
          body
          |> Valimc.Entity.Dragon.boxes()
          |> Enum.with_index()
          |> Enum.map(fn {box, part} ->
            Map.merge(target, %{id: e.entity_id + part + 1, dragon_part: part, box: box})
          end)
        else
          [target]
        end
      end

    players =
      for p <- state.player_bodies,
          do: Map.merge(p, %{ref: {:player, p.uuid}, type: "minecraft:player"})

    List.flatten(mobs) ++ players
  end

  # Native splash/cloud queries ask for LivingEntity, excluding crystals.
  defp living_targets(targets),
    do: Enum.filter(targets, &Valimc.Data.EntityTypes.living?(&1.type))

  defp run_projectile(state, id, entry, {:keep, body, position, effects}, moves) do
    state = Enum.reduce(effects, state, &projectile_effect(&2, entry, &1))
    body = %{body | data: Map.put(body.data, :world_tick, state.game_tick)}
    {state, [%{id: id, revision: entry.revision, position: position, body: body} | moves]}
  end

  defp run_projectile(state, id, entry, {:remove, effects}, moves) do
    store = state.entities.store
    # A hit can change the projectile itself (a crystal's explosion pushes
    # the arrow) before its terminal result. Its current owner removes the
    # current entry, then runs the terminal effects without hitting itself.
    state =
      case store.entries[id] do
        %{revision: revision} ->
          {:ok, store} = Store.remove(store, store.epoch, id, revision)
          put_entities(state, store)

        nil ->
          state
      end

    {Enum.reduce(effects, state, &projectile_effect(&2, entry, &1)), moves}
  end

  defp run_projectile(state, id, entry, {:hurt, target, hit, next}, moves) do
    ignite =
      case target do
        %{ref: {:mob, sid}, uuid: uuid} ->
          case group_entry(state, sid) do
            {_, _, %{entity: %{uuid: ^uuid}, body: %{type: "minecraft:ender_dragon"} = body}} ->
              Valimc.Entity.Dragon.ignites?(body, hit)

            _ ->
              false
          end

        _ ->
          false
      end

    {hurt, state} = projectile_hurt(state, target, hit)
    result = next.(hurt)

    result =
      case result do
        {:keep, body, position, effects} when ignite ->
          {:keep, %{body | data: %{body.data | fire: max(body.data.fire, 20)}}, position, effects}

        _ ->
          result
      end

    run_projectile(state, id, entry, result, moves)
  end

  # A projectile's hit through the one hurt path: an authoritative body of
  # this group (and set on fire when the hit says so), a player by its session,
  # whose hit is taken to land.
  defp projectile_hurt(state, %{ref: {:mob, sid}} = target, hit) do
    case group_entry(state, sid) do
      {key, store, %{entity: %{uuid: uuid}} = entry} ->
        if Map.get(target, :uuid, uuid) == uuid do
          hit =
            if Map.has_key?(target, :dragon_part),
              do: Map.put(hit, :dragon_part, target.dragon_part),
              else: hit

          {change, outcome} = Valimc.Entity.Combat.resolve(entry, hit)

          change =
            case {outcome, change, hit[:ignite]} do
              # A native mob burns in its section (VMC-081d).
              {%{hurt: true}, {:native, _, _, events}, ticks} when is_integer(ticks) ->
                case Native.mob_section_effect(entry.native, sid, {:ignite, ticks}) do
                  {:ok, {_, _, {position, row}}} -> {:native, position, row, events}
                  _ -> change
                end

              _ ->
                change
            end

          state = change_group_entry(state, key, store, sid, change)
          state = combat_feedback(state, entry, outcome)

          state =
            case outcome do
              %{crystal: point} = outcome ->
                state =
                  if outcome.explode, do: explode(state, Explosion.crystal(point)), else: state

                crystal_destroyed(state, entry.entity, hit)

              _ ->
                state
            end

          {outcome.hurt, state}
        else
          {false, state}
        end

      nil ->
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

  defp projectile_effect(state, entry, {:sound_at, _, _, at, volume, _} = event),
    do: terminal_event(state, entry, event, at, 16.0 * max(volume, 1.0))

  defp projectile_effect(state, entry, {:particles, _, at, _, _, _} = event),
    do: terminal_event(state, entry, event, at, 32.0)

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

  # Effects a projectile's hit gives what it hurt (a shulker bullet's).
  defp projectile_effect(state, _entry, {:effects, %{ref: {:player, uuid}}, actions, hit}) do
    send(self(), {:player, uuid, {:splash, actions, hit}})
    state
  end

  defp projectile_effect(state, _entry, {:effects, %{ref: {:mob, sid}} = target, actions, hit}),
    do: Enum.reduce(actions, state, &mob_effect(&2, sid, target, &1, hit))

  defp projectile_effect(state, entry, {:splash, body, location}) do
    living = state |> projectile_targets() |> living_targets()
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
    native_effect(state, sid, {:heal, amount}) || state
  end

  # `canBeAffected` is its section's (VMC-043d: a wither skeleton is never
  # withered).
  defp mob_effect(state, sid, _target, {:add, id, rung}, _template),
    do: add_mob_effect(state, sid, id, rung)

  defp add_mob_effect(state, sid, id, rung) do
    native_effect(state, sid, {:add, id, rung}) || state
  end

  # An effect on a native mob of the group (VMC-081d): its section applies
  # it; nil for any other.
  defp native_effect(state, sid, action) do
    case native_effect_result(state, sid, action) do
      {_, state} -> state
      nil -> nil
    end
  end

  # `{whether it changed, state}`, or nil for a mob that is not native.
  defp native_effect_result(state, sid, action) do
    case group_entry(state, sid) do
      {key, store, %{native: ref}} when ref != nil ->
        case Native.mob_section_effect(ref, sid, action) do
          {:ok, {changed, events, {position, row}}} ->
            {changed == true,
             change_group_entry(state, key, store, sid, {:native, position, row, events})}

          _ ->
            {false, state}
        end

      _ ->
        nil
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
        next = %{next | data: Map.put(next.data, :world_tick, state.game_tick)}

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
              type: owner[:type],
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
        {id, %{kind: :mob, native: ref} = entry}, acc when ref != nil ->
          if Explosion.box_hit?(entry, box) do
            case Native.mob_section_blast(ref, id, :falling_anvil, amount, nil) do
              {:ok, {_, events, {position, row}}} ->
                Store.native_change(acc, id, position, row, events)

              _ ->
                acc
            end
          else
            acc
          end

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

  # An explosion (VMC-050a, `Valimc.World.Explosion`): resolve the group's
  # authoritative entities once, project sibling changes for later hits,
  # notify players through their sessions, and run its crater outside the owner.
  defp explode(state, explosion) do
    case Explosion.reach(explosion) do
      {:ok, cells} ->
        state =
          Enum.reduce(Explosion.sections(explosion), state, fn key, state ->
            store =
              case {key == state.key, state.siblings[key]} do
                {true, _} -> state.entities.store
                {false, %{entities: store}} -> store
                _ -> nil
              end

            if store do
              Enum.reduce(Explosion.hits(explosion, store.entries), state, fn {id, action},
                                                                              state ->
                {^key, store, entry} = group_entry(state, id, true)
                state = change_group_entry(state, key, store, id, Explosion.change(entry, action))

                if action == :destroy and
                     match?(%{body: %Body{type: "minecraft:end_crystal"}}, entry),
                   do: crystal_destroyed(state, entry.entity, %{attacker: nil}),
                   else: state
              end)
            else
              state
            end
          end)

        effects = [{:players, {:explosion, explosion, length(cells)}}]

        %{state | sibling_effects: state.sibling_effects ++ effects}
        |> queue_crater(explosion, cells)

      error ->
        require Logger
        Logger.warning("Explosion at #{inspect(explosion.center)} failed: #{inspect(error)}")
        state
    end
  end

  # Craters wait for the one crater job; past 64 the newest two merge.
  defp queue_crater(state, _explosion, []), do: state

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
    # Cross-owner merging may have taken the planning slot earlier this tick.
    # Even the unsaved simulation marker would invalidate that plan's store fence.
    if planning?(state), do: state, else: move_unplanned_items(state, now)
  end

  defp move_unplanned_items(state, now) do
    # The awake items and the orbs of the simulated chunks, by the spatial
    # index: resting items and the other chunks' entities are not visited
    # (VMC-081l).
    store = state.entities.store
    chunks = state.tickets.simulated

    items =
      for id <- Enum.sort(Valimc.Entity.Spatial.awake(store.spatial, chunks)),
          entry = store.entries[id],
          not Store.simulated?(entry, state.game_tick),
          do: {id, entry}

    orbs =
      for {id, entry} <- Store.in_chunks(store, chunks, :orb),
          not Store.simulated?(entry, state.game_tick),
          do: {id, entry}

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

      state =
        put_in(
          state.entities.store,
          Store.mark_simulated(state.entities.store, Enum.map(steps, & &1.id), state.game_tick)
        )

      {:noreply, state} = commit_simulated_items(state, steps, true)
      state
    end
  end

  # Mobs travel in the entity phase (VMC-015i): the section's simulated mobs
  # take their turns in their section over what it keeps resident (VMC-081d),
  # one at a time in id order; only what changed of them comes back
  # (`Store.native_tick/3`): the steps of those with effects or leaving the
  # section, which land here, in a sibling section in the same commit, or in
  # another group by the handoff.
  defp move_mobs(state) do
    store = state.entities.store
    native = store.native

    # The section picks its mobs itself; the owner counts them by the chunk
    # index only to choose the call's scheduler.
    count = Store.count_in_chunks(store, state.tickets.simulated, :mob)

    dragon_waits =
      count > 0 and Store.has_type?(store, "minecraft:ender_dragon") and
        Enum.any?(state.siblings, fn {key, peer} -> key != state.key and peer.busy end) and
        store
        |> Store.in_chunks(state.tickets.simulated, :mob)
        |> Enum.any?(fn {_, e} -> e.body.type == "minecraft:ender_dragon" end)

    if count == 0 or native == nil or state.mob_world == nil or write_busy(state) != nil or
         dragon_waits do
      state
    else
      {sensed, state} = sensed_items(state)
      # A lazy view: what effects read (eaten and placed blocks).
      view = Valimc.World.View.new(state.dimension)
      random = state.ai_random || Valimc.Data.JavaRandom.create()

      {random, %{moved: moved, changes: changes}} =
        Valimc.Entity.MobTicks.native_tick(
          native,
          {:world, state.mob_world},
          state.game_tick,
          Valimc.Entity.NativeMobs.simulated_mask(state.key, state.tickets.simulated),
          random,
          native_extra(state, count, sensed)
        )

      {ticked, steps} = Store.native_tick(store, moved, changes)
      state = put_in(state.entities.store, ticked)
      steps = Enum.sort_by(steps, & &1.id)

      dragon_effects =
        for step <- steps,
            step.body.type == "minecraft:ender_dragon",
            effect <- step.effects,
            do: {store.entries[step.id].entity, step.position, effect}

      state =
        start_mob_locate(
          %{state | ai_random: random, mob_events: [], mob_located: nil},
          steps
        )

      # A hit's extras (VMC-043b: a burning zombie's fire, a husk's hunger).
      attacks =
        for step <- steps, {:attack, {:player, target}} <- step.effects do
          extras =
            Enum.find_value(step.effects, %{}, fn
              {:attack_extra, {:player, ^target}, extras} -> extras
              _ -> nil
            end)

          {step.id, target, extras}
        end

      # Melee hits on mobs (a guardian's beam on a squid, VMC-043e).
      mob_attacks =
        for step <- steps, {:attack, {:mob, target}} <- step.effects do
          extras =
            Enum.find_value(step.effects, %{}, fn
              {:attack_extra, {:mob, ^target}, extras} -> extras
              _ -> nil
            end)

          {step.id, target, extras}
        end

      # Players an elder guardian curses (VMC-043e).
      curses =
        for step <- steps,
            {:elder_curse, at} <- step.effects,
            %{entity: e, body: body} <- [store.entries[step.id]],
            do: {e, body.type, at}

      # Items a mob picked up (a piglin's gold, VMC-041a2) and drops it let go.
      pickups =
        for step <- steps, {:pickup, {:item, uuid}, n} <- step.effects, do: {step.id, uuid, n}

      drops = for step <- steps, {:drop, stack} <- step.effects, do: {step.position, stack}

      # A hen's egg (VMC-043c): its laying table's item, launched as its AI
      # drew; a lead a mob dropped (VMC-043c3).
      drops =
        drops ++
          for step <- steps,
              effect <- step.effects,
              drop <-
                (case effect do
                   {:lay, velocity} ->
                     for stack <- laid(native.ref, step.id),
                         do: {step.position, stack, velocity}

                   # A gift loot table's items (a grown turtle's scute, VMC-043e).
                   {:gift, table, velocity} ->
                     for stack <- gift(native.ref, step.id, table),
                         do: {step.position, stack, velocity}

                   {:lead, at} ->
                     [{at, Valimc.Protocol.ItemStack.new("minecraft:lead")}]

                   _ ->
                     []
                 end),
              do: drop

      # Knots mobs let go of, and those a restored lead looks for.
      freed = for step <- steps, {:knot_free, pos} <- step.effects, do: pos
      wanted = for step <- steps, {:make_knot, pos} <- step.effects, do: pos

      # Items mobs threw (a piglin's barter, VMC-043d).
      throws =
        for step <- steps,
            effect <- step.effects,
            thrown <- barter(effect),
            is_tuple(thrown) and elem(thrown, 0) == :throw,
            do: thrown

      # Projectiles mobs fired (a blaze's fireballs, VMC-043d) and their level events.
      # Fireballs (VMC-043d) and a witch's splash potions (VMC-043b6).
      shots =
        for step <- steps,
            shot <- step.effects,
            match?({:projectile, _, _, _, _}, shot) or match?({:throw_potion, _}, shot) or
              match?({:throw_trident, _}, shot),
            do: {step.id, shot}

      level_events =
        for step <- steps,
            {:level_event, cell, type, data} <- step.effects,
            do: {cell, type, data}

      # Mobs a spawn brought (a chicken jockey's chicken, VMC-043b) and the
      # chickens that became jockeys.
      companions =
        for step <- steps,
            {:spawn, type, opts} <- step.effects,
            do: {Map.get(opts, :position, step.position), type, opts}

      # Mobs a spawn made and finished at once (a spider jockey's skeleton).
      made =
        for step <- steps,
            {:spawn_body, body, uuid} <- step.effects,
            do: {step.position, body, uuid}

      # Creepers that exploded (VMC-043b4) and mobs simply gone.
      blasts = for step <- steps, {:explode, blast} <- step.effects, do: {step.id, blast}
      gone = for step <- steps, :discard <- step.effects, do: step.id

      jockeys = for step <- steps, {:jockey, uuid} <- step.effects, do: uuid

      # Merchants whose restock checks want their offers (VMC-044b3).
      offers_wanted =
        for step <- steps,
            {:merchant, {:offers_wanted, uuid, owed}} <- step.effects,
            do: {uuid, owed}

      # Arrows skeletons loosed (VMC-043b).
      arrows =
        for step <- steps, {:shoot, shot} <- step.effects, do: {step.id, shot}

      # Mobs that turned into another (a zombie drowning, VMC-043b).
      conversions = for step <- steps, {:convert, to} <- step.effects, do: {step.id, to}

      # Mobs travel through portals (VMC-026d), standing in one too.
      {steps, state} = portal_contacts(state, steps)

      # Farmland mobs trampled (VMC-039a), while mob griefing is on.
      tramples =
        if Valimc.World.GameRules.get(:mob_griefing),
          do: for(step <- steps, {:trample, cell} <- step.effects, do: {:trample, cell}),
          else: []

      # What mobs bring into the level (VMC-043e: a shulker's bullets and
      # offspring).
      fired =
        for step <- steps,
            effect <- step.effects,
            is_tuple(effect) and elem(effect, 0) in [:shoot_bullet, :spawn_mob],
            %{entity: e} <- [store.entries[step.id]],
            do: {e, effect}

      # Hurts mobs deal beyond their melee (VMC-043e): a pufferfish's
      # stings, a guardian's beam and thorns.
      # Players a cube's touch hurts (VMC-043d), as a mob attack that
      # plays its attack sound when it takes.
      touches =
        for step <- steps,
            {:touch, {:player, _} = target, amount, sound} <- step.effects,
            %{entity: e, body: body} <- [store.entries[step.id]],
            do: {e, body.type, target, amount, sound}

      hurts =
        for step <- steps,
            {:hurt, target, type, amount, actions} <- step.effects,
            %{entity: e, body: body} <- [store.entries[step.id]],
            do: {e, body.type, target, type, amount, actions}

      # Turtle eggs mobs landed or stood on (VMC-043e).
      crushes = for step <- steps, {:crush_egg, cell, odds} <- step.effects, do: {cell, odds}

      # Effects mobs give others without a hurt (a dolphin's grace, VMC-043e).
      gifts =
        for step <- steps,
            {:effect, target, actions} <- step.effects,
            %{entity: e, body: body} <- [store.entries[step.id]],
            do: {e, body.type, target, actions}

      # Mobs whose kind ends them (an endermite's lifetime, VMC-043e) leave.
      {discards, steps} = Enum.split_with(steps, &(:discard in &1.effects))
      # A bred pair's child and orb, and the blocks animals ate (VMC-043c).
      born =
        for step <- steps, effect <- step.effects, record <- birth(effect), do: record

      # (A silverfish slipping into stone leaves as it changes the block.)
      eaten =
        for step <- discards ++ steps,
            effect <- step.effects,
            edit <- [mob_edit(view, effect)],
            edit != nil,
            do: edit

      # Infested blocks silverfish woke break into silverfish (VMC-043b6,
      # `InfestedBlock.spawnInfestation`).
      infestations =
        for step <- steps,
            {:wake_infested, {x, y, z}, _, true} <- step.effects,
            do: Valimc.Entity.Body.infestation({x, y, z})

      # The blocks endermen put down (VMC-043b5): set only where they
      # survive; one that does not goes back to its enderman.
      placed =
        for step <- steps,
            {:place_carried, cell, carried} <- step.effects,
            from = Valimc.World.View.block(view, cell),
            from != nil,
            do: {step.id, carried, {:edit, cell, from, carried, nil, [:updates, :survives]}}

      lid_pushes =
        for step <- steps,
            {:shulker_push, area, delta, local} <- step.effects,
            do: {area, delta, local}

      # What moves on: the mobs leaving the section (the others' moves are
      # in the store already).
      routed = Enum.filter(steps, & &1.outside)

      state = route_bodies(state, routed)
      state = settle_native(state, routed)
      state = Enum.reduce(lid_pushes, state, &push_lid(&2, &1))
      state = state |> free_knots(freed) |> make_knots(wanted)
      state = if discards == [], do: state, else: discard_mobs(state, discards)
      state = Enum.reduce(dragon_effects, state, &dragon_effect/2)
      state = Enum.reduce(fired, state, &mob_spawns/2)
      state = Enum.reduce(hurts, state, &mob_hurt/2)
      Enum.each(touches, &mob_touch/1)
      state = Enum.reduce(gifts, state, &mob_gift/2)
      state = if crushes == [], do: state, else: crush_eggs(state, crushes)
      state = Enum.reduce(mob_attacks, state, &mob_attack_mob/2)
      Enum.each(curses, &mob_curse(&1, state.player_sensed))
      state = Enum.reduce(pickups, state, &mob_pickup/2)
      state = if drops == [], do: state, else: mob_drops(state, drops)
      state = if throws == [], do: state, else: mob_throws(state, throws)
      state = Enum.reduce(shots, state, &mob_projectile/2)
      if level_events != [], do: publish_level_events(state, level_events)
      state = if companions == [], do: state, else: mob_companions(state, companions)

      state =
        if made == [],
          do: state,
          else:
            adopt_drops(
              state,
              for({{x, y, z}, record, uuid} <- made, do: %{record | uuid: uuid, x: x, y: y, z: z})
            )

      state = Enum.reduce(blasts, state, &mob_blast/2)
      state = if gone == [], do: state, else: mob_discards(state, gone)
      state = if jockeys == [], do: state, else: mob_jockeys(state, jockeys)
      state = Enum.reduce(offers_wanted, state, &offers_wanted/2)
      state = if conversions == [], do: state, else: mob_conversions(state, conversions)

      state =
        if tramples ++ eaten == [],
          do: state,
          else: elem(rule_run(state, %{actions: tramples ++ eaten}), 0)

      state = if placed == [], do: state, else: carried_placed(state, placed)
      state = if infestations == [], do: state, else: adopt_drops(state, infestations)

      state =
        cond do
          born == [] -> state
          planning?(state) -> put_in(state.entities.dropped, state.entities.dropped ++ born)
          true -> adopt_drops(state, born)
        end

      state = Enum.reduce(arrows, state, &mob_shot/2)

      # Beds villagers lie in or leave and doors they open and close (VMC-044a1).
      state = mob_blocks(state, steps)

      # The tickets its villagers hold, as this tick left them (the same
      # term while unchanged, so its siblings' peers stay as they are).
      claims = Map.new(Native.mob_section_claims(native.ref))
      state = if claims == state.poi_claims, do: state, else: %{state | poi_claims: claims}

      # A mob's melee hit (VMC-041a) goes to the player's session here.
      for {id, target, extras} <- attacks,
          %{entity: %{uuid: uuid}} <- [state.entities.store.entries[id]] do
        mob_attack(state, uuid, target, extras)
      end

      state
    end
  end

  # A projectile mob `id` fired (`addFreshEntity`): a body owned by the mob,
  # moving and turned as its AI made it.
  defp mob_projectile({id, {:projectile, type, at, velocity, {yaw, pitch}}}, state) do
    store = state.entities.store

    case store.entries[id] do
      %{kind: :mob, entity: e, body: %{type: shooter}} ->
        owner = %{uuid: e.uuid, id: e.entity_id, player: false, type: shooter}
        body = Projectile.new(type, owner)
        body = Projectile.impulse(%{body | velocity: velocity, yaw: yaw, pitch: pitch})
        record = Store.body_record(body, :crypto.strong_rand_bytes(16), at)

        case Store.create_record(store, state.key, record) do
          {:ok, store, _} -> put_entities(state, store)
          _ -> state
        end

      _ ->
        state
    end
  end

  # A witch's splash potion and a drowned's trident
  # (`spawnProjectileUsingShoot`): from its eyes, shot with its own spread.
  defp mob_projectile({id, {:throw_trident, info}}, state),
    do: thrown_by(id, "minecraft:trident", info, state)

  defp mob_projectile({id, {:throw_potion, info}}, state),
    do: thrown_by(id, "minecraft:splash_potion", info, state)

  defp thrown_by(id, type, info, state) do
    store = state.entities.store

    case store.entries[id] do
      %{kind: :mob, entity: e, body: %{type: thrower}} ->
        owner = %{uuid: e.uuid, id: e.entity_id, player: false, type: thrower}
        body = Projectile.new(type, owner, info.stack)
        body = Projectile.shoot(body, info.direction, info.velocity, info.uncertainty)
        record = Store.body_record(body, :crypto.strong_rand_bytes(16), info.from)

        case Store.create_record(store, state.key, record) do
          {:ok, store, _} -> put_entities(state, store)
          _ -> state
        end

      _ ->
        state
    end
  end

  # A shulker's bullet at its box's centre, aimed at its target if this
  # group still sees it.
  defp mob_spawns({e, {:shoot_bullet, center, {_, target_uuid}, axis}}, state) do
    targets = projectile_targets(state)
    target = Enum.find(targets, &(&1.uuid == target_uuid))
    owner = %{uuid: e.uuid, id: e.entity_id, player: false, type: "minecraft:shulker"}
    uuid = :crypto.strong_rand_bytes(16)

    body =
      Valimc.Entity.ShulkerBullet.new(owner, center, target, axis, uuid, &read_block(state, &1))

    create_body(state, Store.body_record(body, uuid, center))
  end

  # Infested's silverfish (VMC-037p) come moving, facing a random way, and
  # cry out.
  defp mob_spawns({_e, {:spawn_mob, type, position, data}}, state) do
    {:ok, body} = Body.new(type)
    {velocity, data} = Map.pop(data, :velocity, body.velocity)
    {cry, data} = Map.pop(data, :hurt_sound, false)
    body = %{body | data: Map.merge(body.data, data), velocity: velocity}
    body = if cry, do: %{body | yaw: :rand.uniform() * 360.0}, else: body
    sounds = Valimc.Protocol.CombatPackets.mob_sounds(type)

    if cry and sounds["hurt_sound"] do
      <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

      packet =
        Valimc.Protocol.CombatPackets.sound(
          sounds["hurt_sound"],
          sounds["sound_source"],
          position,
          1.0,
          1.0,
          seed
        )

      Valimc.World.publish(route_key(state), {:sound, position, 16.0, packet})
    end

    create_body(state, Store.body_record(body, :crypto.strong_rand_bytes(16), position))
  end

  # `Pufferfish.touch`: `amount` of mob attack damage and, when it takes,
  # Poison for `poison` ticks (a player's own touch, `playerTouch`, alike).
  # A mob's hurt of `type` on `target` with the effect actions after it (a
  # pufferfish's Poison; `Player.Projectiles.splash/3`'s actions).
  defp mob_touch({e, type, {:player, uuid}, amount, {name, volume, pitch}}) do
    me = %{uuid: e.uuid, entity_id: e.entity_id, player: false, type: type, mainhand: nil}
    source = Valimc.Protocol.CombatPackets.mob_sounds(type)["sound_source"]

    hit = %{
      source: Valimc.Living.DamageSource.new(:mob_attack),
      amount: amount,
      attacker: me,
      direct: me,
      position: {e.x, e.y, e.z},
      taken_sound: {name, source, {e.x, e.y, e.z}, volume, pitch}
    }

    send(self(), {:player, uuid, {:hurt, hit}})
  end

  defp mob_hurt({e, type, target, damage_type, amount, actions}, state) do
    me = %{uuid: e.uuid, entity_id: e.entity_id, player: false, type: type, mainhand: nil}

    hit = %{
      source: Valimc.Living.DamageSource.new(damage_type),
      amount: amount,
      attacker: me,
      direct: me,
      position: {e.x, e.y, e.z}
    }

    case target do
      {:player, uuid} ->
        actions = if type == "minecraft:pufferfish", do: [:puffer_sting | actions], else: actions
        send(self(), {:player, uuid, {:hurt, Map.put(hit, :taken_actions, actions)}})
        state

      {:mob, uuid} ->
        with {:ok, {_, sid, _}} <- Store.find(state.entities.store, uuid),
             {true, state} <- projectile_hurt(state, %{ref: {:mob, sid}}, hit) do
          Enum.reduce(actions, state, &mob_effect(&2, sid, nil, &1, hit))
        else
          {false, state} -> state
          _ -> state
        end
    end
  end

  @turtle_egg Valimc.Data.Blocks.id("turtle_egg")

  @doc """
  Turtle eggs crushed at `crushes` (`[{cell, odds}]`, `destroyEgg`): one chance
  in `odds` each loses an egg, with the break's sound and event (VMC-043e).
  """
  def crush_eggs(state, crushes) do
    effects =
      for {cell, odds} <- crushes,
          in_region?(state, cell),
          block = Blocks.get(state.blocks, cell),
          Valimc.Data.Blocks.block_id(block) == @turtle_egg,
          {next, pitch} <- [Valimc.Blocks.TurtleEgg.crush(block, odds)],
          effect <- [
            {:sound, cell, "minecraft:entity.turtle.egg_break", 0.7, pitch},
            {:set, cell, next},
            {:level_event, cell, 2001, block}
          ],
          do: effect

    apply_tick_effects(state, effects)
  end

  # Effect actions mob `e` gives `target` (`addEffect(effect, mob)`).
  defp mob_gift({e, type, target, actions}, state) do
    me = %{uuid: e.uuid, entity_id: e.entity_id, player: false, type: type, mainhand: nil}
    hit = %{source: nil, amount: 0.0, attacker: me, direct: me, position: {e.x, e.y, e.z}}

    case target do
      {:player, uuid} ->
        send(self(), {:player, uuid, {:splash, actions, hit}})
        state

      {:mob, uuid} ->
        case Store.find(state.entities.store, uuid) do
          {:ok, {_, sid, _}} -> Enum.reduce(actions, state, &mob_effect(&2, sid, nil, &1, hit))
          _ -> state
        end
    end
  end

  # Mob `id`'s melee hit (`doHurtTarget`) on mob `uuid`, with what its
  # family adds to the hit (an iron golem's, VMC-044a2).
  defp mob_attack_mob({id, uuid, own}, state) do
    store = state.entities.store

    with {:ok, {_, sid, _}} <- Store.find(store, uuid),
         # A body or a native mob's row (VMC-081d).
         %{body: %{type: type}} <- store.entries[sid],
         {:ok, hit} <- Valimc.Entity.Combat.mob_hit(store, id, type) do
      elem(projectile_hurt(state, %{ref: {:mob, sid}}, Map.merge(hit, own)), 1)
    else
      _ -> state
    end
  end

  # `ElderGuardian.customServerAiStep`'s curse: Mining Fatigue III for five
  # minutes on survival and adventure players within 50 blocks, each of
  # whom checks what it already has (`MobEffectUtil.addEffectToPlayersAround`).
  defp mob_curse({e, type, {x, y, z}}, players) do
    me = %{uuid: e.uuid, entity_id: e.entity_id, player: false, type: type, mainhand: nil}
    hit = %{source: nil, amount: 0.0, attacker: me, direct: me, position: {x, y, z}}

    curse =
      {:curse, Valimc.Data.EffectTypes.id("mining_fatigue"), {6000, 2, false, true, true}, 1200}

    for %{uuid: uuid, mode: mode, x: px, y: py, z: pz} <- players,
        mode in [:survival, :adventure],
        (px - x) * (px - x) + (py - y) * (py - y) + (pz - z) * (pz - z) < 2500.0 do
      send(self(), {:player, uuid, {:splash, [curse], hit}})
    end
  end

  defp create_body(state, record) do
    case Store.create_record(state.entities.store, state.key, record) do
      {:ok, store, _} -> put_entities(state, store)
      _ -> state
    end
  end

  defp discard_mobs(state, steps) do
    # A creeper that blew up goes as killed (`explodeCreeper`): its effects act.
    removals =
      for %{id: id} <- steps,
          %{body: %{type: "minecraft:creeper"}} = entry <- [state.entities.store.entries[id]],
          r <- removed(id, entry, true),
          do: r

    store =
      Enum.reduce(steps, state.entities.store, fn %{id: id}, store ->
        with %{revision: revision} <- store.entries[id],
             {:ok, next} <- Store.remove(store, store.epoch, id, revision) do
          next
        else
          _ -> store
        end
      end)

    state = publish_item_views(%{state | entities: %{state.entities | store: store}})

    Enum.reduce(removals, state, fn {at, height, actions}, state ->
      removal_effects(state, at, height, actions)
    end)
  end

  # A mob's interaction (VMC-081d): its section's (`kinds::interact`) with
  # the shearing tables rolled here; `{:ok, {:native, position, row,
  # events}, outcome}` in `Leashes.outcome/1`'s shape, `:pass` or
  # `:consume`.
  defp bucket(%{body: %{type: type}} = entry, request) do
    if Valimc.Entity.Bucketable.bucketable?(type) do
      {:ok, body} = Body.restore(Store.record(entry))
      Valimc.Entity.Bucketable.interact(body, request)
    else
      :pass
    end
  end

  ## Merchants (VMC-044b2)

  @villager "minecraft:villager"
  @trader "minecraft:wandering_trader"
  @spawn_egg Valimc.Protocol.ItemTypes.id("villager_spawn_egg")

  # `Villager.mobInteract` and `WanderingTrader.mobInteract`: a busy,
  # sleeping or dead merchant (or a spawn egg) passes; a baby villager is
  # unhappy; offers are made when first asked; without offers a villager
  # is unhappy (main hand) and the use is taken; otherwise it trades with
  # the player, whose session opens the menu (`merchant` in the reply).
  defp merchant_interact(state, %{native: ref, body: %{type: type}, entity: e}, id, request)
       when type in [@villager, @trader] do
    villager = type == @villager
    {view, state} = merchant_act(state, ref, id, :view)
    taken = {:ok, %{hand: :keep, swing: false, others: nil}}

    cond do
      match?(%{item_id: @spawn_egg}, request.item) or not view.alive or view.trading != nil or
        (villager and view.sleeping) or (not villager and view.baby) ->
        :pass

      villager and view.baby ->
        {_, state} = merchant_act(state, ref, id, :unhappy)
        {:merchant, taken, state}

      true ->
        case ensure_offers(state, ref, id, e, view) do
          {:pending, state} ->
            {:merchant, taken, state}

          {[], state} ->
            state =
              if villager and Map.get(request, :hand, :main) == :main,
                do: elem(merchant_act(state, ref, id, :unhappy), 1),
                else: state

            {:merchant, taken, state}

          {_offers, state} ->
            {_, state} =
              merchant_act(state, ref, id, {:start, request.player, Map.get(request, :hero)})

            # `updateSpecialPrices` priced them for the player.
            {%{offers: offers}, state} = merchant_act(state, ref, id, :view)

            trade = %{
              uuid: e.uuid,
              villager: villager,
              offers: offers,
              level: if(villager, do: view.level, else: 1),
              xp: if(villager, do: view.xp, else: 0),
              title: merchant_title(view)
            }

            {:merchant, {:ok, %{hand: :keep, swing: not villager, others: nil, merchant: trade}},
             state}
        end
    end
  end

  defp merchant_interact(_state, _entry, _id, _request), do: :pass

  # `getDisplayName`: its name, else its profession's or the trader's.
  defp merchant_title(%{custom_name: name}) when name != nil, do: name

  defp merchant_title(%{type: @villager, profession: "minecraft:" <> profession}),
    do: Valimc.Text.translatable("entity.minecraft.villager." <> profession)

  defp merchant_title(_view), do: Valimc.Text.translatable("entity.minecraft.wandering_trader")

  defp merchant_act(state, ref, id, action) do
    case Native.mob_section_merchant(ref, id, action) do
      {:ok, {result, events, {position, row}}} ->
        {result,
         put_entities(state, Store.native_change(state.entities.store, id, position, row, events))}

      _ ->
        {{:error, :missing}, state}
    end
  end

  defp merchant_of(view, {x, y, z}, level) do
    %{
      profession: if(view.type == @villager, do: view.profession),
      level: level,
      # A wandering trader has no villager variant: no predicate holds.
      villager_type: view.villager_type || "",
      position: {x, y, z}
    }
  end

  # `getOffers`: made at its level the first time (`updateTrades`).
  defp ensure_offers(state, _ref, _id, _e, %{offers: offers}) when is_list(offers),
    do: {offers, state}

  defp ensure_offers(state, ref, id, e, view) do
    level = if view.type == @villager, do: view.level, else: 0
    merchant = merchant_of(view, {e.x, e.y, e.z}, level)

    case draw_offers(state, %{uuid: e.uuid, merchant: merchant, answers: [], append: false}) do
      {:ok, offers, state} ->
        {_, state} = merchant_act(state, ref, id, {:offers, offers})
        {offers, state}

      {:pending, state} ->
        {:pending, state}
    end
  end

  # `increaseMerchantCareer`'s `updateTrades`: the new level's offers join.
  defp level_up_offers(state, ref, id, uuid, at, traded) do
    {view, state} = merchant_act(state, ref, id, :view)
    merchant = merchant_of(view, at, traded.level)

    case draw_offers(state, %{uuid: uuid, merchant: merchant, answers: [], append: true}) do
      {:ok, more, state} ->
        offers = traded.offers ++ more
        {_, state} = merchant_act(state, ref, id, {:offers, offers})
        {offers, state}

      {:pending, state} ->
        {traded.offers, state}
    end
  end

  # A draw, or a structure search queued for its exploration map.
  defp draw_offers(state, waiting) do
    case Valimc.World.Trades.draw(waiting.merchant, waiting.answers) do
      {:ok, offers} ->
        {:ok, offers, state}

      {:locate, tag, radius} ->
        {:pending, queue_trade_locate(state, Map.put(waiting, :tag, {tag, radius}))}

      {:error, reason} ->
        require Logger
        Logger.warning("Merchant offers not drawn: #{inspect(reason)}")
        {:pending, state}
    end
  end

  defp queue_trade_locate(state, waiting) do
    waiting = %{waiting | tag: elem(waiting.tag, 0)} |> Map.put(:radius, elem(waiting.tag, 1))

    if length(state.trade_waiting) >= 64 do
      state
    else
      start_trade_locate(%{state | trade_waiting: state.trade_waiting ++ [waiting]})
    end
  end

  # The first waiting merchant's search, one at a time.
  defp start_trade_locate(%{trade_waiting: [waiting | _]} = state) do
    if Jobs.running?(state.jobs, :trade_locate) do
      state
    else
      dimension = state.dimension
      members = Valimc.Blocks.Loot.structure_tag(waiting.tag)
      {x, y, z} = waiting.merchant.position
      origin = {floor(x), floor(y), floor(z)}
      radius = min(waiting.radius, 100)

      work = fn ->
        case Valimc.Worldgen.Locate.nearest(dimension, members, origin, radius) do
          {:ok, {x, y, z, _id}} -> {:ok, {x, y, z}}
          result -> result
        end
      end

      case start_job(state, :trade_locate, work,
             supervisor: Valimc.TransferWorkers,
             deadline: 60_000,
             data: %{uuid: waiting.uuid}
           ) do
        {:ok, state} -> state
        {:error, _} -> state
      end
    end
  end

  defp start_trade_locate(state), do: state

  # The draw again with the answers so far; offers made join the merchant,
  # if it is still here and still wants them.
  defp waiting_draw(state, waiting) do
    state =
      case draw_offers(state, Map.delete(waiting, :tag) |> Map.delete(:radius)) do
        {:ok, offers, state} -> place_offers(state, waiting, offers)
        {:pending, state} -> state
      end

    start_trade_locate(state)
  end

  defp place_offers(state, waiting, offers) do
    store = state.entities.store

    with {:ok, {_, id, _}} <- Store.find(store, waiting.uuid),
         %{native: ref} when ref != nil <- store.entries[id] do
      {view, state} = merchant_act(state, ref, id, :view)

      cond do
        waiting.append and is_list(view.offers) ->
          elem(merchant_act(state, ref, id, {:offers, view.offers ++ offers}), 1)

        not waiting.append and view.offers == nil ->
          elem(merchant_act(state, ref, id, {:offers, offers}), 1)

        true ->
          state
      end
    else
      _ -> state
    end
  end

  # `shouldRestock`'s `getOffers`: a merchant without offers draws them now,
  # with the demand updates a new day's catch-up owes them (VMC-044b3).
  defp offers_wanted({uuid, owed}, state) do
    store = state.entities.store

    with false <- Enum.any?(state.trade_waiting, &(&1.uuid == uuid)),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{native: ref, entity: e} when ref != nil <- store.entries[id],
         {%{offers: nil} = view, state} <- merchant_act(state, ref, id, :view),
         {offers, state} when is_list(offers) <- ensure_offers(state, ref, id, e, view) do
      owed_offers =
        Enum.reduce(1..owed//1, offers, fn _, o -> Valimc.Menus.Offers.update_demand(o) end)

      if owed > 0,
        do: elem(merchant_act(state, ref, id, {:offers, owed_offers}), 1),
        else: state
    else
      {:pending, state} -> state
      {_view, %{} = state} -> state
      _ -> state
    end
  end

  # `rewardTradeXp`'s orb, half a block up.
  defp traded_orb(state, _at, nil), do: state

  defp traded_orb(state, {x, y, z}, pop),
    do: create_group_body(state, ExperienceOrbs.single({x, y + 0.5, z}, pop))

  defp native_interaction(%{native: ref, body: row}, id, request) do
    holder = request[:holder]

    player =
      holder &&
        {request.player, {holder.x, holder.y, holder.z}, holder.id, holder.width, holder.height}

    loot = shearing_loot(ref, id, row, request.item)

    case Native.mob_section_interact(ref, id, request.item, player, request.infinite, loot) do
      {:ok,
       {{:done, hand, swing, events, others, drops, convert, free, discard}, own, {pos, row}}} ->
        seeded =
          Enum.map(events, fn
            {kind, sound, source, volume, pitch} ->
              <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
              {kind, sound, source, volume, pitch, seed}

            event ->
              event
          end)

        {:ok, {:native, pos, row, own},
         %{
           hand: hand,
           swing: swing,
           events: seeded,
           others: others,
           drops: drops,
           convert: convert,
           free: free,
           discard: discard
         }}

      {:ok, {outcome, _, _}} when outcome in [:pass, :consume] ->
        outcome

      {:error, _} ->
        {:error, :missing_item}
    end
  end

  @shears Valimc.Protocol.ItemTypes.id("minecraft:shears")

  # The shearing table a sheep or mooshroom rolls, rolled here.
  defp shearing_loot(ref, id, %NativeBody{type: type}, %{item_id: @shears})
       when type in ["minecraft:sheep", "minecraft:mooshroom"] do
    table =
      if type == "minecraft:sheep",
        do: "minecraft:shearing/sheep",
        else: "minecraft:shearing/mooshroom"

    properties = Native.mob_section_properties(ref, id)

    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    case Valimc.Blocks.Loot.entity_drops(table, seed, {0.0, 0.0, 0.0}, %{properties: properties}) do
      {:ok, stacks} -> [{table, stacks}]
      _ -> []
    end
  end

  defp shearing_loot(_ref, _id, _row, _item), do: []

  # What an interaction did: the body (a native mob's
  # `{:native, position, row, events}`) changed in place, or (a conversion)
  # the old entity gone and the new one in its place with the events; its
  # drops launched from it.
  defp interacted(state, id, revision, {x, y, z} = at, body, outcome) do
    store = state.entities.store

    {state, store} =
      if Map.get(outcome, :discard, false) do
        state =
          Enum.reduce(outcome.events, state, fn
            {:sound, name, source, volume, pitch, _seed}, state ->
              projectile_effect(state, nil, {:sound, name, source, at, volume, pitch})

            _, state ->
              state
          end)

        {:ok, store} = Store.remove(store, store.epoch, id, revision)
        {state, store}
      else
        {state,
         case {outcome.convert, body} do
           {nil, {:native, position, row, events}} ->
             Store.native_change(store, id, position, row, events ++ outcome.events)

           {nil, body} ->
             Store.change_body(store, id, body, outcome.events)

           {new, _} ->
             uuid = :crypto.strong_rand_bytes(16)

             # A native mob becomes the record its section made.
             record =
               case new do
                 %Body{} -> Store.body_record(new, uuid, at)
                 record -> Map.put(record, :uuid, uuid)
               end

             with {:ok, store} <- Store.remove(store, store.epoch, id, revision),
                  {:ok, store, {_, new_id, _}} <- Store.create_record(store, state.key, record) do
               new = if match?(%Body{}, new), do: new, else: store.entries[new_id].body
               Store.change_body(store, new_id, new, outcome.events)
             else
               _ -> store
             end
         end}
      end

    state = publish_item_views(%{state | entities: %{state.entities | store: store}})

    drops =
      for {stack, {dx, dy, dz}, launch} <- outcome.drops do
        [vx, vz] = for _ <- 1..2, do: :rand.uniform_real()
        {ax, ay, az} = {vx * 0.2 - 0.1, 0.2, vz * 0.2 - 0.1}

        velocity =
          case launch do
            nil -> {ax, ay, az}
            {:add, {bx, by, bz}} -> {ax + bx, ay + by, az + bz}
          end

        {{x + dx, y + dy, z + dz}, stack, velocity}
      end

    if drops == [], do: state, else: mob_drops(state, drops)
  end

  # A breeding's child where its parent stood, facing south, and its orb
  # (`new ExperienceOrb`: one orb of the value).
  defp birth({:offspring, type, data, at}) do
    {:ok, body} = Valimc.Entity.Body.new(type)
    [Store.body_record(%{body | data: data}, :crypto.strong_rand_bytes(16), at)]
  end

  defp birth({:orb, value, at}), do: [ExperienceOrbs.single(at, value)]
  defp birth(_effect), do: []

  # Fence knots (VMC-043c3, `LeashFenceKnotEntity`): `pos => network id`;
  # a knot's entity stands at its block's corner, as vanilla spawns it.
  @knot "minecraft:leash_knot"
  @fences MapSet.new(Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:fences"])
  @lead_item Valimc.Protocol.ItemTypes.id("minecraft:lead")

  defp knots(state) do
    if group_knots?(state) do
      for {id, %{kind: :object, body: %Body{type: @knot}, entity: e}} <-
            group_entries(state),
          into: %{},
          do: {{floor(e.x), floor(e.y), floor(e.z)}, id}
    else
      %{}
    end
  end

  defp fence?(state, pos) do
    case Blocks.get(state.blocks, pos) do
      nil -> false
      block -> MapSet.member?(@fences, Valimc.Data.Blocks.block_id(block))
    end
  end

  # The owning group's authoritative stores, including this callback's changes.
  defp group_stores(state) do
    [{state.key, state.entities.store}] ++
      for {key, %{entities: store}} <- state.siblings, key != state.key, do: {key, store}
  end

  defp group_entries(state),
    do: Enum.flat_map(group_stores(state), fn {_, store} -> Map.to_list(store.entries) end)

  # Whether the group may hold a knot: this store's, or a sibling's as the
  # group handed in which do (`knotted`) without asking each sibling.
  defp group_knots?(%{knotted: %MapSet{} = knotted} = state),
    do:
      Store.has_type?(state.entities.store, @knot) or
        Enum.any?(knotted, &(&1 != state.key and Map.has_key?(state.siblings, &1)))

  defp group_knots?(state), do: group_has_type?(state, @knot)

  defp group_has_type?(state, type),
    do:
      Store.has_type?(state.entities.store, type) or
        Enum.any?(state.siblings, fn {key, peer} ->
          key != state.key and Store.has_type?(peer.entities, type)
        end)

  defp group_entry(state, id, allow_busy \\ false) do
    Enum.find_value(group_stores(state), fn {key, store} ->
      case store.entries[id] do
        nil ->
          nil

        entry ->
          if allow_busy or key == state.key or not state.siblings[key].busy,
            do: {key, store, entry}
      end
    end)
  end

  defp change_group_entry(state, _key, _store, _id, :keep), do: state

  defp change_group_entry(state, key, store, id, change) do
    revision = store.entries[id].revision
    {:ok, next} = Store.change_entry(store, id, revision, change)

    if key == state.key do
      put_entities(state, next)
    else
      # Resolve drops once too: a later explosion must see them. The same
      # records and reserved ids enter the sibling before the next operation.
      {next, deaths} = Store.take_deaths(next)
      records = Enum.flat_map(deaths, &death_records/1)

      {records, next} =
        Enum.map_reduce(records, next, fn record, store ->
          {:ok, store, {_, spawned, _}} = Store.create_record(store, key, record)
          {Map.put(record, :entity_id, spawned), store}
        end)

      state = put_in(state.siblings[key].entities, next)
      state = sibling_effect(state, key, {:entity_change, id, revision, change})
      if records == [], do: state, else: sibling_effect(state, key, {:entities, nil, records})
    end
  end

  # The group's mobs as leads see them: `{id, body, position}`.
  defp leash_mobs(state) do
    for {id, %{kind: :mob, body: body, entity: e}} <- group_entries(state),
        do: {id, body, {e.x, e.y, e.z}}
  end

  # A knot no mob is tied to any more goes (`notifyLeasheeRemoved`).
  defp free_knots(state, []), do: state

  defp free_knots(state, positions) do
    {own, other} = Enum.split_with(Enum.uniq(positions), &(block_section(&1) == state.key))

    held =
      for {_, %{kind: :mob, body: body}} <- group_entries(state),
          %{holder: {:knot, pos}} <- [Valimc.Entity.Leashes.leash(body)],
          into: MapSet.new(),
          do: pos

    state =
      own
      |> Enum.reject(&MapSet.member?(held, &1))
      |> Enum.flat_map(&List.wrap(knots(state)[&1]))
      |> Enum.reduce(state, &remove_entry(&2, &1))

    Enum.reduce(Enum.group_by(other, &block_section/1), state, fn {key, positions}, state ->
      sibling_effect(state, key, {:free_knots, positions})
    end)
  end

  # Restored leads make their knot in the section holding the fence.
  defp make_knots(state, positions) do
    Enum.reduce(Enum.uniq(positions), state, fn pos, state ->
      cond do
        Map.has_key?(knots(state), pos) -> state
        block_section(pos) == state.key -> elem(new_knot(state, pos), 0)
        true -> sibling_effect(state, block_section(pos), {:make_knots, [pos]})
      end
    end)
  end

  defp block_section({x, _, z}), do: Grid.region_key(Grid.chunk_key(x, z))

  defp sibling_effect(state, key, effect) do
    if Map.has_key?(state.siblings, key),
      do: %{state | sibling_effects: state.sibling_effects ++ [{key, effect}]},
      else: state
  end

  defp new_knot(state, {x, y, z}) do
    {:ok, body} = Body.new(@knot)
    body = %{body | data: %{since: state.game_tick || 0}}
    record = Store.body_record(body, :crypto.strong_rand_bytes(16), {x * 1.0, y * 1.0, z * 1.0})

    case Store.create_record(state.entities.store, state.key, record) do
      {:ok, store, {_, id, _}} -> {put_entities(state, store), id}
      _ -> {state, nil}
    end
  end

  defp remove_entry(state, id) do
    store = state.entities.store

    with %{revision: revision} <- store.entries[id],
         {:ok, store} <- Store.remove(store, store.epoch, id, revision) do
      put_entities(state, store)
    else
      _ -> state
    end
  end

  # A knot's sound (`playSound`: neutral, at the knot).
  defp knot_sound(state, {x, y, z}, name) do
    at = {x + 0.5, y + 0.375, z + 0.5}
    packet = Valimc.World.Sounds.packet(name, :neutral, at, :rand.uniform(1 <<< 62))
    Valimc.World.publish(route_key(state), {:sound, at, 16.0, packet})
    state
  end

  # Mobs whose lead changed (`{id, body}`), each with its drops.
  defp leash_ready?(state, changes) do
    Enum.all?(changes, fn change ->
      id = elem(change, 0)

      Enum.any?(group_stores(state), fn {key, store} ->
        Map.has_key?(store.entries, id) and (key == state.key or not state.siblings[key].busy)
      end)
    end)
  end

  defp releash(state, changes) do
    Enum.reduce(changes, state, fn {id, body}, state ->
      {key, store} =
        Enum.find(group_stores(state), fn {_, store} -> Map.has_key?(store.entries, id) end)

      change =
        case body do
          %NativeBody{leash: leash} -> {:leash, leash && {leash.holder, leash.id}}
          body -> {:body, body, []}
        end

      change_group_entry(state, key, store, id, change)
    end)
  end

  # `BlockAttachedEntity.tick`: support checks count executed turns. Inactive
  # gaps and global game-time jumps do not advance the 101-turn interval.
  defp tick_knots(state) do
    if Store.has_type?(state.entities.store, @knot),
      do: tick_knot_checks(state),
      else: state
  end

  defp tick_knot_checks(state) do
    Enum.reduce(Store.in_chunks(state.entities.store, state.tickets.simulated, :object), state, fn
      {id, %{body: %Body{type: @knot}, entity: e} = entry}, state ->
        checks = div(Map.get(entry, :lived, 0), 101)

        if checks > Map.get(entry, :knot_checks, 0) do
          state = put_in(state.entities.store.entries[id], Map.put(entry, :knot_checks, checks))
          pos = {floor(e.x), floor(e.y), floor(e.z)}

          if fence?(state, pos),
            do: state,
            else: state |> remove_entry(id) |> knot_sound(pos, "minecraft:item.lead.untied")
        else
          state
        end

      _, state ->
        state
    end)
  end

  # A player's use of a fence (VMC-043c3, `LeadItem.bindPlayerMobs`): the
  # player's mobs around it that reach it move to its knot, made where none
  # is; the knot's sound plays. `{:used, state}` or `:pass`.
  defp fence_use(state, epoch, position, grant) do
    now = System.monotonic_time(:millisecond)

    with true <- epoch == state.epoch and valid_block_query?([position], :any),
         true <- in_region?(state, position),
         %{kind: :open, mode: mode, eye: eye, expires: expires, player: player} <- grant,
         true <- mode != :spectator and is_integer(expires) and now < expires,
         true <- Valimc.Living.Interaction.within_block?(mode, eye, position),
         # Sneaking with an item skips the fence's use; a lead binds anyway
         # (`LeadItem.useOn`).
         true <-
           not (grant[:secondary] == true and (grant[:main] == true or grant[:off] == true)) or
             grant[:main_item] == @lead_item,
         nil <- write_busy(state),
         true <- fence?(state, position),
         existing = knots(state)[position],
         [_ | _] = moved <-
           Valimc.Entity.Leashes.bind(leash_mobs(state), player, {position, existing}),
         true <- leash_ready?(state, moved) do
      {state, id} = if existing, do: {state, existing}, else: new_knot(state, position)

      moved =
        for {mob, body} <- moved do
          case body do
            %NativeBody{} -> {mob, put_in(body.leash.id, id)}
            body -> {mob, put_in(body.mob.leash.id, id)}
          end
        end

      {:swing, state |> releash(moved) |> knot_sound(position, "minecraft:item.lead.tied")}
    else
      _ -> :pass
    end
  end

  @grass_block Valimc.Data.Blocks.default_state("grass_block")
  @dirt Valimc.Data.Blocks.default_state("dirt")
  @carrots Valimc.Data.Blocks.id("carrots")

  # What a mob ate as a block-rule edit of the state it reads now: a sheep's
  # grass turns to dirt (`EatBlockGoal`, after grass's break event), the
  # plant it stands in breaks without drops, a raided carrot loses a stage
  # (its youngest goes, quietly).
  defp mob_edit(view, {:eat_block, cell, :dirt}) do
    case Valimc.World.View.block(view, cell) do
      nil -> nil
      from -> {:edit, cell, from, @dirt, @grass_block}
    end
  end

  defp mob_edit(view, {:eat_block, cell, :destroy}) do
    case Valimc.World.View.block(view, cell) do
      nil -> nil
      from -> {:edit, cell, from, nil, nil}
    end
  end

  defp mob_edit(view, {:raid_carrot, cell}) do
    with from when from != nil <- Valimc.World.View.block(view, cell),
         @carrots <- Valimc.Data.Blocks.block_id(from),
         {"age", age} <- List.keyfind(Valimc.Data.Blocks.properties(from), "age", 0) do
      case String.to_integer(age) do
        0 ->
          {:edit, cell, from, Valimc.Data.Blocks.default_state("air"), nil}

        n ->
          {:edit, cell, from, Valimc.Data.Blocks.state("carrots", %{"age" => "#{n - 1}"}), from}
      end
    else
      _ -> nil
    end
  end

  # A turtle's eggs on the sand (`setBlockAndUpdate`, VMC-043e) where the air
  # still is.
  defp mob_edit(view, {:lay_eggs, cell, n}) do
    with from when from != nil <- Valimc.World.View.block(view, cell),
         true <- Valimc.Data.BlockFacts.air?(from) do
      {:edit, cell, from, Valimc.Data.Blocks.state("turtle_egg", %{"eggs" => "#{n}"}), nil,
       [:updates]}
    else
      _ -> nil
    end
  end

  # An enderman takes a block (`removeBlock`): its fluid, neighbours updated.
  defp mob_edit(view, {:take_block, cell, taken}) do
    case Valimc.World.View.block(view, cell) do
      ^taken -> {:edit, cell, taken, Valimc.Data.BlockFacts.fluid_remains(taken), nil, [:updates]}
      _ -> nil
    end
  end

  # A turtle egg a mob cracked (`decreaseEggs`, VMC-043b2): one egg fewer
  # (its break event), the last breaking the block.
  defp mob_edit(view, {:crack_egg, cell, state}) do
    if Valimc.World.View.block(view, cell) == state do
      to = cracked(state)

      options =
        if Valimc.Data.Blocks.block_id(to) == Valimc.Data.Blocks.block_id(state),
          do: [],
          else: [:updates]

      {:edit, cell, state, to, state, options}
    end
  end

  defp mob_edit(view, {:dragon_break, cell, expected}) do
    case Valimc.World.View.block(view, cell) do
      ^expected ->
        {:edit, cell, expected, Valimc.Data.BlockFacts.fluid_remains(expected), nil, [:updates]}

      _ ->
        nil
    end
  end

  # A zombie stamps out turtle eggs (`removeBlock`, VMC-043b2).
  defp mob_edit(view, {:remove_block, cell}) do
    case Valimc.World.View.block(view, cell) do
      nil -> nil
      from -> {:edit, cell, from, Valimc.Data.BlockFacts.fluid_remains(from), nil, [:updates]}
    end
  end

  # A silverfish slips into stone: it becomes infested (`setBlockAndUpdate`).
  defp mob_edit(view, {:infest, cell, infested}) do
    from = Valimc.World.View.block(view, cell)

    if from != nil and infested_of(from) != nil,
      do: {:edit, cell, from, infested, nil, [:updates]}
  end

  # A woken infested block breaks (`destroyBlock`, its break event first)
  # while mobs may grief, else turns back to its stone.
  defp mob_edit(view, {:wake_infested, cell, state, griefing}) do
    if Valimc.World.View.block(view, cell) == state do
      if griefing,
        do: {:edit, cell, state, Valimc.Data.BlockFacts.fluid_remains(state), state, [:updates]},
        else: {:edit, cell, state, host_of(state), nil, [:updates]}
    end
  end

  defp mob_edit(_view, _effect), do: nil

  # A turtle egg block after one egg cracks (`TurtleEggBlock.decreaseEggs`):
  # one egg fewer, or the block's fluid for the last.
  defp cracked(state) do
    properties = Map.new(Valimc.Data.Blocks.properties(state))

    case Integer.parse(Map.get(properties, "eggs", "1")) do
      {n, ""} when n > 1 ->
        Valimc.Data.Blocks.state("turtle_egg", %{properties | "eggs" => Integer.to_string(n - 1)})

      _ ->
        Valimc.Data.BlockFacts.fluid_remains(state)
    end
  end

  # `infestedStateByHost`: the infested form of a host state (nil for none),
  # and back (`hostStateByInfested`), with the same properties.
  defp infested_of(state) do
    case Valimc.Data.Blocks.id(
           "infested_" <> Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(state))
         ) do
      nil -> nil
      block -> carry(state, block)
    end
  end

  defp host_of(state) do
    "infested_" <> host = Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(state))
    carry(state, Valimc.Data.Blocks.id(host))
  end

  defp carry(state, block),
    do:
      Valimc.Data.Blocks.state(
        Valimc.Data.Blocks.name(block),
        Map.new(Valimc.Data.Blocks.properties(state))
      )

  # Endermen's blocks put down in one run; each that was not set returns to
  # its enderman, still in this section and carrying nothing.
  defp carried_placed(state, placed) do
    {state, outcome} = rule_run(state, %{actions: Enum.map(placed, &elem(&1, 2))})
    results = if outcome, do: outcome.results, else: Enum.map(placed, fn _ -> 0 end)

    Enum.zip(placed, results)
    |> Enum.reduce(state, fn
      {{id, carried, _}, 0}, state ->
        store = state.entities.store

        case store.entries[id] do
          %{kind: :mob, body: %Body{data: %{carried: nil} = data} = body} ->
            put_entities(
              state,
              Store.change_body(store, id, %{body | data: %{data | carried: carried}})
            )

          %{kind: :mob, native: ref, body: %NativeBody{data: %{carried: nil}}} when ref != nil ->
            put_entities(state, native_data(store, ref, id, :carried, carried))

          _ ->
            state
        end

      _, state ->
        state
    end)
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

  # `spawnAtLocation`: stacks a mob lets go, where it stands (with the launch
  # its AI drew, or a fresh one).
  defp mob_drops(state, drops) do
    records =
      for drop <- drops do
        {{x, y, z}, stack, velocity} =
          case drop do
            {at, stack} ->
              [vx, vz] = for _ <- 1..2, do: :rand.uniform_real()
              {at, stack, {vx * 0.2 - 0.1, 0.2, vz * 0.2 - 0.1}}

            three ->
              three
          end

        %{
          uuid: :crypto.strong_rand_bytes(16),
          x: x,
          y: y,
          z: z,
          stack: stack,
          motion: %Valimc.Entity.ItemMotionState{velocity: velocity, pickup_delay: 10}
        }
      end

    adopt_drops(state, records)
  end

  # `dropFromGiftLootTable(table)` of mob `id` of section `ref`.
  defp gift(ref, id, table) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    properties = Native.mob_section_properties(ref, id)

    case Valimc.Blocks.Loot.entity_drops(table, seed, {0.0, 0.0, 0.0}, %{properties: properties}) do
      {:ok, stacks} -> stacks
      _ -> []
    end
  end

  # `dropFromGiftLootTable(CHICKEN_LAY)`: the egg of the hen's variant.
  defp laid(ref, id) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    properties = Native.mob_section_properties(ref, id)

    case Valimc.Blocks.Loot.entity_drops(
           "minecraft:gameplay/chicken_lay",
           seed,
           {0.0, 0.0, 0.0},
           %{
             properties: properties
           }
         ) do
      {:ok, stacks} -> stacks
      _ -> []
    end
  end

  # Mobs another mob's spawn made (`mobs::ai::spawn`): a chicken jockey's
  # chicken, already finalized from the spawning mob's draws, or a mob that
  # finishes its own spawn on its first tick (a husk's camel husk).
  defp mob_companions(state, companions) do
    records =
      for {position, type, opts} <- companions,
          {:ok, body} <- [Body.spawned(type, Map.get(opts, :reason))] do
        body = companion(body, opts)
        Store.body_record(body, :crypto.strong_rand_bytes(16), position)
      end

    adopt_drops(state, records)
  end

  # `BehaviorUtils.throwItem`: each item from where and as fast as the mob
  # threw it, picked up after the default delay.
  # A native piglin's barter (VMC-081d): the bartering table rolled with its
  # seed, each item thrown from its hand at its velocity.
  defp barter({:barter, seed, from, velocity}) do
    {:ok, items} = Valimc.Blocks.Loot.barter(seed)
    for stack <- items, do: {:throw, stack, from, velocity}
  end

  defp barter(effect), do: [effect]

  defp mob_throws(state, throws) do
    records =
      for thrown <- throws do
        # A dolphin's toss waits 40 ticks (VMC-043e).
        {stack, {x, y, z}, velocity, delay} =
          case thrown do
            {:throw, stack, at, velocity} -> {stack, at, velocity, 10}
            {:throw, stack, at, velocity, delay} -> {stack, at, velocity, delay}
          end

        %{
          uuid: :crypto.strong_rand_bytes(16),
          x: x,
          y: y,
          z: z,
          stack: stack,
          motion: %Valimc.Entity.ItemMotionState{velocity: velocity, pickup_delay: delay}
        }
      end

    adopt_drops(state, records)
  end

  @doc false
  def companion(body, %{jockey: true, follow_bonus: _} = opts) do
    mob = body.mob
    follow = "minecraft:follow_range"
    entry = %{base: nil, modifiers: [{"minecraft:random_spawn_bonus", opts.follow_bonus, 1}]}

    %{
      body
      | yaw: opts.yaw,
        head_yaw: opts.yaw,
        data: %{body.data | jockey: true},
        mob: %{
          mob
          | left_handed: opts.left_handed,
            attributes: Map.put(mob.attributes, follow, entry)
        }
    }
  end

  # A mount whose own spawn the rider's drew (a drowned's zombie nautilus):
  # it faces as the rider does.
  def companion(body, %{jockey: true, yaw: yaw}), do: %{body | yaw: yaw, head_yaw: yaw}

  # A mob another summoned (a villagers' iron golem, VMC-044a2): its
  # `finalizeSpawn` was drawn when it was made.
  def companion(body, %{summoned: true} = opts) do
    mob = body.mob
    follow = "minecraft:follow_range"
    entry = %{base: nil, modifiers: [{"minecraft:random_spawn_bonus", opts.follow_bonus, 1}]}

    %{
      body
      | yaw: opts.yaw,
        head_yaw: opts.yaw,
        mob: %{
          mob
          | left_handed: opts.left_handed,
            attributes: Map.put(mob.attributes, follow, entry)
        }
    }
  end

  def companion(body, _opts), do: body

  # A skeleton's arrow (`performRangedAttack`, VMC-043b3).
  defp mob_shot({id, shot}, state) do
    case state.entities.store.entries[id] do
      %{kind: :mob, entity: %{uuid: uuid}, body: %{type: type}} ->
        effect =
          case arrow_effect(type) do
            nil -> nil
            {name, ticks} -> {Valimc.Data.EffectTypes.id(name), {ticks, 0, false, true, true}}
          end

        # The bow in its hand arms the arrow (VMC-037q: Power, Punch, Flame).
        weapon =
          case state.entities.store.entries[id].body do
            %{shown: {_, _, equipment, _}} -> equipment[:mainhand]
            _ -> nil
          end

        opts = %{from: shot.from, pitch: shot.pitch, effect: effect, weapon: weapon}

        case mob_shoot(state, uuid, shot.at, shot.power, opts) do
          {:ok, state} -> state
          _ -> state
        end

      _ ->
        state
    end
  end

  # The effect a stray's or a bogged's arrow carries (`getArrow`).
  defp arrow_effect("minecraft:stray"), do: {"slowness", 600}
  defp arrow_effect("minecraft:bogged"), do: {"poison", 100}
  defp arrow_effect(_type), do: nil

  # `Mob.convertTo`: the converted mob takes the old one's place (a new
  # entity, as vanilla's), the old one is discarded.
  defp mob_conversions(state, conversions) do
    {difficulty, _} = Clock.difficulty()
    level = elem({:peaceful, :easy, :normal, :hard}, difficulty.level)

    special =
      Valimc.Living.LocalDifficulty.special(
        Valimc.Living.LocalDifficulty.at(level, Clock.day_ticks())
      )

    {store, records} =
      Enum.reduce(conversions, {state.entities.store, []}, fn {id, to}, {store, records} ->
        uuid = :crypto.strong_rand_bytes(16)

        with %{kind: :mob, entity: e, revision: revision} = entry <- store.entries[id],
             {:ok, record} <- converted(entry, id, uuid, to, special, {e.x, e.y, e.z}),
             {:ok, next} <- Store.remove(store, store.epoch, id, revision) do
          {next, [record | records]}
        else
          _ -> {store, records}
        end
      end)

    state = publish_item_views(%{state | entities: %{state.entities | store: store}})
    adopt_drops(state, Enum.reverse(records))
  end

  # A family field of a native mob set by its section (VMC-081d).
  defp native_data(store, ref, id, key, value) do
    case Native.mob_section_data(ref, id, key, value) do
      {:ok, {_, events, {position, row}}} -> Store.native_change(store, id, position, row, events)
      _ -> store
    end
  end

  # The halves a dead cube becomes as it is removed: `{body, position}`, a
  # native one's `{record, position}` (VMC-081d, `Kind::split`).
  defp cube_split(id, %{native: ref, body: %NativeBody{alive: false}}) when ref != nil,
    do: Native.mob_section_split(ref, id)

  defp cube_split(_id, _entry), do: []

  # A dead (or exploded, `killed`) native mob's removal effects:
  # `[{position, height, actions}]`.
  defp removed(id, entry, killed \\ false)

  defp removed(id, %{native: ref, body: %NativeBody{alive: alive}}, killed)
       when ref != nil and (killed or not alive) do
    case Native.mob_section_removed(ref, id, Valimc.World.GameRules.get(:mob_griefing)) do
      {_, _, []} -> []
      {at, height, actions} -> [{at, height, actions}]
      _ -> []
    end
  end

  defp removed(_id, _entry, _killed), do: []

  # What a living entity's effects do as it goes (VMC-037p,
  # `MobEffect.onMobRemoved`): Wind Charged's burst at the middle of its box,
  # Weaving's cobwebs, Oozing's slimes.
  defp removal_effects(state, {x, y, z} = at, height, actions) do
    Enum.reduce(actions, state, fn
      {:wind_burst, strength}, state ->
        middle = y + Valimc.Data.Float32.round(height / 2.0)
        explode(state, Explosion.wind({x, middle, z}, strength))

      {:cobwebs, count, cells}, state ->
        weave(state, count, cells)

      {:slimes, count}, state ->
        ooze(state, at, height, count)
    end)
  end

  # `WeavingMobEffect.spawnCobwebsRandomlyAround`: the first `count` distinct
  # cells that can be replaced over a sturdy floor take cobwebs (with their
  # particles, level event 3018).
  defp weave(state, count, cells) do
    view = Valimc.World.View.new()
    cobweb = Valimc.Data.Blocks.default_state("cobweb")

    chosen =
      cells
      |> Enum.uniq()
      |> Enum.reduce_while([], fn {x, y, z} = cell, chosen ->
        from = Valimc.World.View.block(view, cell)
        below = Valimc.World.View.block(view, {x, y - 1, z})

        chosen =
          if from != nil and below != nil and Valimc.Blocks.PortalBlocks.replaceable?(from) and
               Valimc.Blocks.PortalBlocks.sturdy_up?(below),
             do: [{cell, from} | chosen],
             else: chosen

        if length(chosen) >= count, do: {:halt, chosen}, else: {:cont, chosen}
      end)
      |> Enum.reverse()

    if chosen == [] do
      state
    else
      actions = for {cell, from} <- chosen, do: {:edit, cell, from, cobweb, nil, [:updates]}
      {state, _} = rule_run(state, %{actions: actions})
      publish_level_events(state, for({cell, _} <- chosen, do: {cell, 3018, 0}))
      state
    end
  end

  # `OozingMobEffect`: size-2 slimes half a block up, as many as asked while
  # the slimes within two blocks of its box stay under `max_entity_cramming`.
  defp ooze(state, {x, y, z}, height, count) do
    cramming = Valimc.World.GameRules.get(:max_entity_cramming)

    count =
      if cramming < 1 do
        count
      else
        box = {x - 2.3, y - 2.0, z - 2.3, x + 2.3, y + height + 2.0, z + 2.3}

        nearby =
          for {_, %{kind: :mob, body: %{type: "minecraft:slime"}} = entry} <- group_entries(state),
              Explosion.box_hit?(entry, box),
              do: 1

        min(count, max(0, cramming - min(length(nearby), cramming)))
      end

    Enum.reduce(List.duplicate(nil, count), state, fn _, state ->
      yaw = :rand.uniform() * 360.0
      {:ok, record} = Native.mob_section_fresh_sized("minecraft:slime", 2, yaw)
      {:ok, body} = Body.restore(record)
      create_body(state, Store.body_record(body, :crypto.strong_rand_bytes(16), {x, y + 0.5, z}))
    end)
  end

  # The record of the mob a mob becomes, from its section (VMC-081d), at
  # its entity's place.
  defp converted(%{native: ref}, id, uuid, to, special, {x, y, z}) when ref != nil do
    with {:ok, record} <- Native.mob_section_convert(ref, id, uuid, to, special),
         do: {:ok, %{record | x: x, y: y, z: z}}
  end

  defp converted(_entry, _id, _uuid, _to, _special, _position), do: :error

  # `Creeper.explodeCreeper` (VMC-043b4): `level.explode(this, ...,
  # ExplosionInteraction.MOB)`: it breaks blocks only while mobs may grief,
  # its drops decaying by the mob explosion rule.
  defp mob_blast({_id, blast}, state) do
    griefing = Valimc.World.GameRules.get(:mob_griefing)

    explosion = %Explosion{
      center: blast.center,
      radius: blast.radius * 1.0,
      decay: Valimc.World.GameRules.get(:mob_explosion_drop_decay),
      blocks: griefing,
      interacts: griefing
    }

    explode(state, explosion)
  end

  # Mobs that left the world without dying (`discard`): a creeper that
  # exploded.
  defp mob_discards(state, ids) do
    store =
      Enum.reduce(ids, state.entities.store, fn id, store ->
        with %{revision: revision} <- store.entries[id],
             {:ok, next} <- Store.remove(store, store.epoch, id, revision) do
          next
        else
          _ -> store
        end
      end)

    publish_item_views(%{state | entities: %{state.entities | store: store}})
  end

  # `setChickenJockey`: the chickens baby zombies chose to ride.
  defp mob_jockeys(state, uuids) do
    store =
      Enum.reduce(uuids, state.entities.store, fn uuid, store ->
        with {:ok, {_, id, _}} <- Store.find(store, uuid),
             %{kind: :mob, body: %{data: %{jockey: false}} = body} = entry <- store.entries[id] do
          case entry do
            %{native: ref} when ref != nil -> native_data(store, ref, id, :jockey, true)
            _ -> Store.change_body(store, id, %{body | data: %{body.data | jockey: true}})
          end
        else
          _ -> store
        end
      end)

    put_entities(state, store)
  end

  # At most one structure query per section runs under the existing bounded
  # workers and generation pool. Busy requests are re-emitted by their live goal;
  # no separate queue accumulates while a worker is occupied.
  defp start_mob_locate(state, steps) do
    request =
      for step <- steps, {:locate, uuid, token, query} <- step.effects, do: {uuid, token, query}

    if Jobs.running?(state.jobs, :mob_locate) or request == [] do
      state
    else
      {uuid, token, query} = hd(request)
      dimension = state.dimension

      work = fn ->
        members = Valimc.Blocks.Loot.structure_tag(query.tag)

        case Valimc.Worldgen.Locate.nearest(dimension, members, query.position, query.radius) do
          {:ok, {x, y, z, _id}} -> {:ok, {x, y, z}}
          result -> result
        end
      end

      case start_job(state, :mob_locate, work,
             supervisor: Valimc.TransferWorkers,
             deadline: 60_000,
             data: %{uuid: uuid, request: token}
           ) do
        {:ok, state} -> state
        {:error, _} -> state
      end
    end
  end

  @doc """
  What native mobs' turns read of the level (VMC-081d), for the group's
  `MobWorld` once a tick at game tick `tick` in `dimension`: the clock,
  difficulty, sky, weather, game rules, height, sea level, border and
  biome zoom seed (`Native.mob_world_set/2`'s `level`). A section's knots
  and its tests' goals ride its own tick (`native_extra/2`).
  """
  def native_level(dimension, tick) do
    {min_y, height} = Valimc.World.Dimension.bounds(dimension)
    {difficulty, _} = Valimc.World.Clock.difficulty()
    day = Clock.day_ticks()
    name = Valimc.World.Dimension.name(dimension)
    overworld = dimension == :overworld

    %{rain_level: rain, thunder_level: thunder} =
      if overworld, do: Clock.weather(), else: %{rain_level: 0.0, thunder_level: 0.0}

    {zoom_seed, _} = Valimc.World.Spec.client_info(Valimc.World.Spec.current(), dimension)

    darken =
      Valimc.World.Spawning.darken(name, day, rain, Valimc.Data.Float32.round(thunder * rain))

    border = Valimc.World.Clock.border_snapshot()
    fixed_time = Valimc.Data.SleepFacts.dimension(dimension).fixed_time

    %{
      time: tick || 0,
      day: day,
      difficulty: elem({:peaceful, :easy, :normal, :hard}, difficulty.level),
      darken: darken,
      bright: not fixed_time and darken < 4,
      fixed_time: fixed_time,
      monsters_burn: overworld and Valimc.Data.HostileFacts.monsters_burn?(day),
      halloween: halloween?(),
      mob_griefing: Valimc.World.GameRules.get(:mob_griefing),
      mob_drops: Valimc.World.GameRules.get(:mob_drops),
      entity_drops: Valimc.World.GameRules.get(:entity_drops),
      universal_anger: false,
      goals: true,
      min_y: min_y,
      max_y: min_y + height - 1,
      sea_level: Valimc.World.Dimension.sea_level(dimension),
      border: border && elem(Valimc.Physics.BorderSnapshot.bounds(border), 1),
      knots: [],
      wet: Clock.weather().wet,
      zoom_seed: zoom_seed,
      dimension: dimension
    }
  end

  # What a section's native tick reads beside its group's world (VMC-081d):
  # the items its mobs sense, the knots where the group holds any, whether
  # goals run (tests turn them off per scope), the players' anger events,
  # the dragon's arena and an answered structure query.
  defp native_extra(state, units, sensed) do
    # Its mobs (the turns the call takes) choose its scheduler.
    extra = %{units: units}
    extra = if sensed == [], do: extra, else: Map.put(extra, :items, sensed)

    extra =
      if group_knots?(state),
        do: Map.put(extra, :knots, Enum.to_list(knots(state))),
        else: extra

    extra =
      if Application.get_env(:valimc, :mob_goals) != nil,
        do: Map.put(extra, :goals, Valimc.config(:mob_goals, state.key) != false),
        else: extra

    extra = if state.mob_events != [], do: Map.put(extra, :events, state.mob_events), else: extra

    extra =
      if Store.has_type?(state.entities.store, "minecraft:ender_dragon"),
        do: Map.put(extra, :dragon, native_dragon(state)),
        else: extra

    case state.mob_located do
      {{uuid, token}, {:ok, {x, y, z}}} -> Map.put(extra, :located, [{uuid, token, {x, y, z}}])
      {{uuid, token}, _} -> Map.put(extra, :located, [{uuid, token, nil}])
      _ -> extra
    end
  end

  # What mobs' AI senses of the section's items, packed
  # (`mob_section_level::compact_item`): `{uuid, x, y, z, item, count,
  # pickup_delay, in_water, components}`, components nil when empty.
  # Built again only when a simulated chunk holds an awake item or the
  # spatial index counted a change of one (added or gone, moved, its stack
  # changed): a resting item's place, stack, pickup delay and water flag
  # stay, and an item outside the simulated chunks neither moves nor ages
  # (VMC-081l).
  defp sensed_items(state) do
    store = state.entities.store
    stamp = {store.epoch, store.spatial.items}

    with {^stamp, items} <- state.entities.sensed,
         [] <- Valimc.Entity.Spatial.awake(store.spatial, state.tickets.simulated) do
      {items, state}
    else
      _ ->
        items =
          for {{_, :item}, ids} <- store.spatial.chunks,
              id <- ids,
              %{kind: :item, entity: e, stack: stack} = entry <- [store.entries[id]] do
            motion = Map.get(entry, :motion)

            {e.uuid, e.x * 1.0, e.y * 1.0, e.z * 1.0, stack.item_id, stack.count,
             if(motion, do: motion.pickup_delay, else: 0), motion != nil and motion.in_water,
             if(stack.components == %{}, do: nil, else: stack.components)}
          end

        {items, %{state | entities: %{state.entities | sensed: {stamp, items}}}}
    end
  end

  # Mobs whose steps left the section and did not go (a handoff that could
  # not start yet) take back their state from before the tick; those an
  # outgoing handoff carries wait for it.
  defp settle_native(%{entities: %{store: %{native: nil}}} = state, _steps), do: state

  defp settle_native(state, steps) do
    if Enum.any?(steps, &Map.get(&1, :outside, false)) do
      :ok = Native.mob_section_settle(state.entities.store.native.ref, state.native_departing)
    end

    state
  end

  defp dragon_effect({entity, {x, y, z}, {:dragon_contact, target, push, amount, wing}}, state) do
    # Its wing or head's `mob_attack` from where it is now.
    me = %{
      uuid: entity.uuid,
      entity_id: entity.entity_id,
      player: false,
      type: "minecraft:ender_dragon",
      mainhand: nil
    }

    hit = %{
      source: Valimc.Living.DamageSource.new(:mob_attack),
      amount: amount,
      attacker: me,
      direct: me,
      position: {x * 1.0, y * 1.0, z * 1.0}
    }

    case target do
      {:player, uuid} ->
        send(self(), {:player, uuid, {:dragon_contact, hit, push, wing}})
        state

      {:mob, uuid} ->
        case Enum.find(group_entries(state), fn {_, e} -> e.entity.uuid == uuid end) do
          {id, _} ->
            case group_entry(state, id) do
              {key, store, %{native: ref} = entry} when ref != nil ->
                # A native mob (VMC-081d): pushed, then hit, in its section.
                recent = wing and entry.body.recent
                hit = if amount > 0.0 and not recent, do: hit, else: %{hit | amount: 0.0}

                case Native.mob_section_hit(ref, id, hit, push) do
                  {:ok, {_, events, {position, row}}} ->
                    change_group_entry(state, key, store, id, {:native, position, row, events})

                  _ ->
                    state
                end

              _ ->
                state
            end

          _ ->
            state
        end
    end
  end

  defp dragon_effect({e, _, {:fireball, at, direction}}, state) do
    owner = %{uuid: e.uuid, id: e.entity_id, player: false, type: "minecraft:ender_dragon"}
    body = Projectile.new("minecraft:dragon_fireball", owner)

    body =
      Projectile.impulse(%{
        body
        | velocity: direction,
          data: Map.put(body.data, :world_tick, state.game_tick)
      })

    create_group_body(state, Store.body_record(body, :crypto.strong_rand_bytes(16), at))
  end

  defp dragon_effect({e, _, {:dragon_flame, uuid, at}}, state) do
    owner = %{uuid: e.uuid, id: e.entity_id, player: false, type: "minecraft:ender_dragon"}
    body = EffectCloud.dragon_breath(owner)

    body = %{
      body
      | data:
          body.data
          |> Map.merge(%{radius: 5.0, duration: 200, radius_per_tick: 0.0})
          |> Map.put(:world_tick, state.game_tick)
    }

    create_group_body(state, Store.body_record(body, uuid, at))
  end

  defp dragon_effect({_, _, {:dragon_end_flame, uuid}}, state) do
    case Enum.find(group_entries(state), fn {_, e} -> e.entity.uuid == uuid end) do
      {id, _} ->
        case group_entry(state, id) do
          {key, store, _} -> change_group_entry(state, key, store, id, :remove)
          _ -> state
        end

      _ ->
        state
    end
  end

  defp dragon_effect({_, _, {:dragon_xp, amount, at}}, state),
    do: Enum.reduce(ExperienceOrbs.drop(at, amount), state, &create_group_body(&2, &1))

  defp dragon_effect({_, {x, y, z}, {:global_event, id}}, state) do
    packet = Valimc.Protocol.Packets.level_event(id, {floor(x), floor(y), floor(z)}, 0, true)
    Valimc.Player.PlayerList.broadcast({:packet, packet})
    state
  end

  defp dragon_effect({e, _, :dragon_killed}, state) do
    if state.key == {0, 0},
      do: Valimc.World.Dragon.Arena.complete(state, e.uuid, arena_ops()),
      else: sibling_effect(state, {0, 0}, {:dragon_killed, e.uuid})
  end

  defp dragon_effect(_, state), do: state

  @doc "The origin section's fight before the group's entity phase."
  def dragon_arena_tick(state, players \\ []),
    do: Valimc.World.Dragon.Arena.tick(state, arena_ops(), players)

  defp arena_ops do
    %{
      ready: fn state ->
        write_busy(state) == nil and Enum.all?(state.siblings, fn {_, peer} -> not peer.busy end)
      end,
      entries: &group_entries/1,
      edits: &arena_edits/2,
      spawn: &arena_spawn/1,
      gateway: &arena_gateway/2,
      ritual: &arena_ritual/2,
      queue: fn state, effect ->
        %{state | sibling_effects: state.sibling_effects ++ [{state.key, effect}]}
      end,
      event: fn state, id, at ->
        {x, _, z} = at
        route = Grid.section(state.dimension, Grid.chunk_key(x, z))
        Valimc.World.publish(route, {:level_events, [{at, id, 0}]})
        state
      end,
      packet: fn uuid, packet -> send(self(), {:player, uuid, {:boss_packet, packet}}) end
    }
  end

  defp arena_spawn(state) do
    {:ok, body} = Body.new("minecraft:ender_dragon")

    {yaw, random} =
      Valimc.Data.JavaRandom.next_float(state.ai_random || Valimc.Data.JavaRandom.create())

    yaw = Valimc.Data.Float32.round(yaw * 360.0)
    body = %{body | yaw: yaw, head_yaw: yaw, data: %{body.data | phase: 0}}
    uuid = :crypto.strong_rand_bytes(16)
    record = Store.body_record(body, uuid, {0.0, 128.0, 0.0})
    state = create_body(%{state | ai_random: random}, record)

    case Store.find(state.entities.store, uuid) do
      {:ok, _} -> {state, uuid}
      _ -> {state, nil}
    end
  end

  # Native feature intents use the existing fenced rules, drops, container
  # spills, neighbour updates and one shared group frame.
  defp arena_edits(state, intents) do
    view = Valimc.World.View.new(state.dimension)
    {min_y, height} = Valimc.World.Dimension.bounds(state.dimension)

    intents =
      Enum.filter(intents, fn {{_, y, _}, _, _} -> y >= min_y and y < min_y + height end)

    cells = Enum.map(intents, &elem(&1, 0))
    initial = Map.new(Enum.zip(cells, Valimc.World.View.blocks(view, cells)))

    {_projected, actions} =
      Enum.reduce(intents, {initial, []}, fn {cell, block, drops}, {projected, actions} ->
        old = Map.get(projected, cell)

        next =
          cond do
            old == nil or old == block ->
              []

            drops and not Valimc.Data.BlockFacts.air?(old) ->
              [
                {:edit, cell, old, nil, nil, [:drops]},
                {:edit, cell, Valimc.Data.BlockFacts.fluid_remains(old), block, nil, [:updates]}
              ]

            true ->
              [{:edit, cell, old, block, nil, [:updates]}]
          end

        {Map.put(projected, cell, block), Enum.reverse(next, actions)}
      end)

    {state, _} = rule_run(state, %{actions: Enum.reverse(actions)})
    state
  end

  defp arena_gateway(state, at) do
    type = Valimc.Blocks.BlockEntityTypes.type_id(Valimc.Data.Blocks.default_state("end_gateway"))
    {:ok, nbt} = BlockEntities.encode_nbt({:compound, %{"Age" => {:long, 0}}})
    key = Grid.region_key(Grid.chunk_key(elem(at, 0), elem(at, 2)))
    entry = %{at => {type, nbt}}

    state =
      if key == state.key do
        {:ok, entities} = BlockEntities.add(state.block_entities, entry)
        %{state | block_entities: entities}
      else
        sibling_effect(state, key, {:arena_entries, entry})
      end

    intents =
      for {cell, block} <- Valimc.World.Portal.Gateway.structure(at), do: {cell, block, false}

    arena_edits(state, intents)
  end

  defp arena_ritual(state, {:beam, uuids, target}) do
    arena_crystals(state, fn entry ->
      if entry.entity.uuid in uuids, do: %{entry.body.data | beam: target}, else: entry.body.data
    end)
  end

  defp arena_ritual(state, :reset_spike_crystals) do
    arena_crystals(state, fn entry ->
      if Valimc.World.Dragon.Ritual.on_spike?(entry.entity, state.arena_spikes),
        do: %{entry.body.data | invulnerable: false, beam: nil},
        else: entry.body.data
    end)
  end

  defp arena_ritual(state, {kind, spike}) when kind in [:pillar_clear, :pillar_build] do
    {clear, build} = Map.fetch!(state.arena_pillars, {spike.x, spike.z})
    intents = Valimc.World.Dragon.Ritual.intents(if kind == :pillar_clear, do: clear, else: build)
    state = arena_edits(state, intents)

    if kind == :pillar_build do
      {:ok, body} = Body.new("minecraft:end_crystal")

      {yaw, random} =
        Valimc.Data.JavaRandom.next_float(state.ai_random || Valimc.Data.JavaRandom.create())

      body = %{
        body
        | yaw: Valimc.Data.Float32.round(yaw * 360.0),
          data: %{body.data | invulnerable: true, beam: {0, 128, 0}}
      }

      record =
        Store.body_record(
          body,
          :crypto.strong_rand_bytes(16),
          {spike.x + 0.5, spike.height + 1.0, spike.z + 0.5}
        )

      create_group_body(%{state | ai_random: random}, record)
    else
      state
    end
  end

  defp arena_ritual(state, {:pillar_blast, spike}) do
    # Every block the power-five rays can reach lies inside the cleared
    # 21-cube. Keep the native entity damage and large particle without
    # starting an asynchronous empty crater.
    explode(state, %Explosion{
      center: {spike.x + 0.5, spike.height * 1.0, spike.z + 0.5},
      radius: 5.0,
      blocks: false
    })
  end

  defp arena_ritual(state, {:ritual_explode, uuid, position}) do
    # Capture all positions before the first blast: earlier blasts may
    # discard later crystals, but native still explodes every listed one.
    state =
      arena_crystals(state, fn entry ->
        if entry.entity.uuid == uuid, do: %{entry.body.data | beam: nil}, else: entry.body.data
      end)

    state =
      case Enum.find(group_entries(state), fn {_, e} -> e.entity.uuid == uuid end) do
        {id, _} ->
          {key, store, _} = group_entry(state, id)
          change_group_entry(state, key, store, id, :remove)

        nil ->
          state
      end

    explode(state, %Explosion{center: position, radius: 6.0, blocks: false, interacts: false})
  end

  defp arena_crystals(state, change) do
    ids = for {id, %{body: %Body{type: "minecraft:end_crystal"}}} <- group_entries(state), do: id

    Enum.reduce(ids, state, fn id, state ->
      {key, store, entry} = group_entry(state, id)
      data = change.(entry)

      if data == entry.body.data,
        do: state,
        else: change_group_entry(state, key, store, id, {:body, %{entry.body | data: data}, []})
    end)
  end

  defp crystal_destroyed(state, crystal, hit) do
    if Valimc.World.Dimension.facts(state.dimension).dragon_fight do
      state = arena_crystal_change(state, crystal.uuid)
      point = {floor(crystal.x), floor(crystal.y), floor(crystal.z)}

      player =
        case hit[:attacker] do
          %{player: true, uuid: uuid} ->
            Enum.find(state.player_sensed, &(&1.uuid == uuid))

          _ ->
            state.player_sensed
            |> Enum.filter(fn p ->
              p.alive and p.mode not in [:creative, :spectator] and not p.invulnerable and
                squared({p.x, p.y, p.z}, point) <= 4096.0
            end)
            |> Enum.min_by(&squared({&1.x, &1.y, &1.z}, point), fn -> nil end)
        end

      player =
        if player do
          %{
            id: player.id,
            position: {player.x, player.y, player.z},
            height: player.height,
            eligible:
              player.alive and player.mode not in [:creative, :spectator] and
                not player.invulnerable,
            attacker: %{
              uuid: player.uuid,
              entity_id: player.id,
              player: true,
              type: "minecraft:player",
              mainhand: nil
            }
          }
        end

      arena = state.arena || get_in(state.siblings, [{0, 0}, :arena])

      dragons =
        for {id, %{body: %{type: "minecraft:ender_dragon"}, entity: e}} <-
              group_entries(state),
            arena == nil or arena.dragon == e.uuid,
            do: id

      Enum.reduce(dragons, state, fn id, state ->
        case group_entry(state, id) do
          # A native dragon (VMC-081d) in its section, over its arena.
          {key, store, %{native: ref}} when ref != nil ->
            striker =
              player &&
                {player.id, player.position, player.height * 1.0, player.eligible,
                 player.attacker}

            case Native.mob_section_dragon_crystal(
                   ref,
                   state.mob_world,
                   native_level(state.dimension, state.game_tick),
                   id,
                   crystal.uuid,
                   {crystal.uuid, crystal.entity_id,
                    {crystal.x * 1.0, crystal.y * 1.0, crystal.z * 1.0}},
                   striker,
                   native_dragon(state)
                 ) do
              {:ok, {_, events, {position, row}}} ->
                change_group_entry(state, key, store, id, {:native, position, row, events})

              _ ->
                state
            end

          _ ->
            state
        end
      end)
    else
      state
    end
  end

  defp arena_crystal_change(state, uuid) do
    arena = state.arena || get_in(state.siblings, [{0, 0}, :arena])

    if arena do
      count = Valimc.World.Dragon.Arena.count_crystals(state, arena_ops())
      arena = %{arena | alive_crystals: count, scan: 0}

      if state.arena do
        Valimc.World.Dragon.Ritual.destroyed(%{state | arena: arena}, uuid, arena_ops())
      else
        {projected, _} = Valimc.World.Dragon.Fight.crystal_destroyed(arena, uuid)
        state = put_in(state.siblings[{0, 0}].arena, projected)
        sibling_effect(state, {0, 0}, {:arena_crystal_destroyed, count, uuid})
      end
    else
      state
    end
  end

  defp squared({x, y, z}, {a, b, c}),
    do: (x - a) * (x - a) + (y - b) * (y - b) + (z - c) * (z - c)

  # A dragon's head/cloud can lie in a sibling even before its root moves.
  defp create_group_body(state, %{x: x, z: z} = record) do
    key = Grid.region_key(Grid.chunk_key(x, z))

    cond do
      key == state.key ->
        create_body(state, record)

      match?(%{busy: false}, state.siblings[key]) ->
        store = state.siblings[key].entities

        case Store.create_record(store, key, record) do
          {:ok, next, {_, id, _}} ->
            state = put_in(state.siblings[key].entities, next)
            sibling_effect(state, key, {:entities, nil, [Map.put(record, :entity_id, id)]})

          _ ->
            state
        end

      true ->
        state
    end
  end

  # A dragon's arena (VMC-081d, `mob_tick`'s `dragon`): the fight's crystal
  # count and whether it was won before and the group's end crystals (its
  # section reads the mobs its wings and head may touch).
  defp native_dragon(state) do
    arena = state.arena || get_in(state.siblings, [{0, 0}, :arena])
    entries = group_entries(state)

    crystals =
      for {_, %{body: %Body{type: "minecraft:end_crystal"} = body, entity: e}} <- entries do
        {w, h, _} = Body.dimensions(body)
        {x, y, z} = {e.x * 1.0, e.y * 1.0, e.z * 1.0}
        {e.uuid, {x, y, z}, {x - w / 2, y, z - w / 2, x + w / 2, y + h, z + w / 2}}
      end

    %{
      crystals: arena && arena.alive_crystals,
      previous_kill: arena == nil or arena.previous_kill,
      crystal_bodies: crystals
    }
  end

  # `SpawnUtil.isHalloween` of vanilla's `LocalDate.now()`, the host's own
  # date: October 20 to November 3.
  defp halloween? do
    case :calendar.local_time() do
      {{_, 10, day}, _} -> day >= 20
      {{_, 11, day}, _} -> day <= 3
      _ -> false
    end
  end

  # `MOB_INTERACTABLE_DOORS`.
  @mob_doors MapSet.new(
               Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:mob_interactable_doors"]
             )

  # `startSleeping` and `stopSleeping` set a bed's `occupied` (its foot
  # follows its head), `DoorBlock.setOpen` a wooden door's `open` through the
  # rules (its other half, its sound); each where it still is what the mob saw.
  defp mob_blocks(state, steps) do
    beds = for step <- steps, {:bed, cell, occupied} <- step.effects, do: {cell, occupied}
    doors = for step <- steps, {:door, cell, open} <- step.effects, do: {cell, open}
    state = Enum.reduce(beds, state, &bed_occupied/2)

    uses =
      for {cell, open} <- Enum.uniq(doors),
          block = local_or_sibling_block(state, cell),
          block != nil and MapSet.member?(@mob_doors, Valimc.Data.Blocks.block_id(block)) and
            List.keyfind(Valimc.Data.Blocks.properties(block), "open", 0) !=
              {"open", to_string(open)},
          do: {:use, cell, 2, true}

    if uses == [], do: state, else: elem(rule_run(state, %{actions: uses}), 0)
  end

  defp bed_occupied({head, occupied}, state) do
    with bed when is_integer(bed) <- local_or_sibling_block(state, head),
         true <- Valimc.Data.Blocks.class(bed) == "BedBlock" do
      foot = Valimc.Player.Sleep.behind(head, Valimc.Player.Sleep.facing(bed))

      cells =
        for {cell, block} <- [{head, bed}, {foot, local_or_sibling_block(state, foot)}],
            is_integer(block) and Valimc.Data.Blocks.class(block) == "BedBlock",
            do: {cell, Valimc.Player.Sleep.occupied(block, occupied)}

      Enum.reduce(Enum.group_by(cells, &route_of(state, elem(&1, 0))), state, fn
        {key, changes}, state ->
          part = %{changes: changes, destroyed: [], ticks: [], fluid_ticks: [], events: []}

          if key == state.key,
            do: apply_rules(state, part),
            else: %{state | sibling_effects: state.sibling_effects ++ [{key, {:rules, part}}]}
      end)
    else
      _ -> state
    end
  end

  # The section key (`state.key`'s kind) of a cell.
  defp route_of(state, {x, _, z}) do
    {_, sx, sz} = Grid.section(state.dimension, Grid.chunk_key(x, z))
    {sx, sz}
  end

  # A cell of this section or a sibling's (nil where the group holds none).
  defp local_or_sibling_block(state, cell) do
    key = route_of(state, cell)

    cond do
      key == state.key -> Blocks.get(state.blocks, cell)
      sibling = state.siblings[key] -> Blocks.get(sibling.blocks, cell)
      true -> nil
    end
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
      # Native mobs it carries keep their section's fallback until it ends.
      handed = for %{native: true, id: id} <- Enum.take(batch, 32), do: id

      case plan_item_change(
             :item_handoff_out,
             {destination, Enum.take(batch, 32), deadline},
             nil,
             state
           ) do
        {:noreply, state} -> %{state | native_departing: handed}
        {:reply, _, state} -> state
      end
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
    with :pass <- shear_use(state, epoch, viewer, position, grant),
         :pass <- harvest_use(state, epoch, viewer, position, grant),
         :pass <- redstone_use(state, epoch, viewer, position, grant),
         :pass <- fence_use(state, epoch, position, grant) do
      {decision, state} = menu_request(state, epoch, viewer, position, grant)
      {:reply, decision, state}
    else
      {:used, state} -> {:reply, :used, state}
      # `SUCCESS_SERVER`: the server swings the player's arm.
      {:swing, state} -> {:reply, :swing, state}
      {:sheared, state} -> {:reply, :sheared, state}
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
         true <- menu in Valimc.Menus.MenuAccess.containers() or {:error, :missing_container},
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
      # A shulker box drops with its contents from its entry's retirement.
      records = ContainerSpills.without_boxes(records, Map.get(plan, :removed, []))
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

  # Crystal placement and the hosted player's item use share this group frame.
  def handle_call({:place_crystal, epoch, {x, y, z} = position, player_boxes}, _from, state) do
    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         true <-
           valid_block_query?([position, {x, y + 1, z}], :any) or {:error, :invalid_block_query},
         true <- in_region?(state, position) or {:error, :wrong_region},
         nil <- write_busy(state),
         {:ok, point} <-
           Valimc.Entity.EndCrystal.placement(position, &read_block(state, &1), player_boxes),
         {:ok, body} <- Body.new("minecraft:end_crystal"),
         body = put_in(body.data.bottom, false),
         record = Store.body_record(body, :crypto.strong_rand_bytes(16), point),
         {:ok, store, _} <- Store.create_record(state.entities.store, state.key, record) do
      state = put_entities(state, store)

      state =
        if state.arena,
          do: Valimc.World.Dragon.Ritual.try_respawn(state, arena_ops()),
          else: sibling_effect(state, {0, 0}, :arena_try_respawn)

      {:reply, :ok, state}
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
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
         %{body: %Body{} = body} <- store.entries[id],
         true <- takeable?(body, actor),
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
  # other entity is removed. A killed dragon completes its fight at once, as
  # `EnderDragon.kill` calls `setDragonKilled`: the exit portal and the egg,
  # without the death animation. The reply counts the entities killed.
  def handle_call({:kill_entities, epoch, uuids}, _from, state) do
    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state) do
      {store, killed, dragons} =
        Enum.reduce(uuids, {state.entities.store, 0, []}, fn uuid, {store, killed, dragons} ->
          with {:ok, {_, id, _}} <- Store.find(store, uuid),
               dragon? = match?(%{body: %{type: "minecraft:ender_dragon"}}, store.entries[id]),
               {:ok, next} <- Store.kill(store, id) do
            dragons = if dragon?, do: [uuid | dragons], else: dragons
            {next, killed + 1, dragons}
          else
            _ -> {store, killed, dragons}
          end
        end)

      state =
        Enum.reduce(
          dragons,
          put_entities(state, store),
          &dragon_effect({%{uuid: &1}, nil, :dragon_killed}, &2)
        )

      {:reply, {:ok, killed}, state}
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # `/effect` over this section's mobs (VMC-037p): each mob's section
  # applies `{:add, id, rung}`, `{:remove, id}` or `{:clear}`. The reply
  # holds the uuids it changed.
  def handle_call({:effect_entities, epoch, uuids, action}, _from, state) do
    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state) do
      {changed, state} =
        Enum.reduce(uuids, {[], state}, fn uuid, {changed, acc} ->
          with {:ok, {_, sid, _}} <- Store.find(acc.entities.store, uuid),
               {true, next} <- native_effect_result(acc, sid, action) do
            {[uuid | changed], next}
          else
            {false, next} -> {changed, next}
            _ -> {changed, acc}
          end
        end)

      {:reply, {:ok, changed}, state}
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

  # A player's use of an item on a mob (VMC-043c): a bucket's catch, else
  # its section's (`kinds::interact`: the lead part, then its family's). Its
  # change (or the mob it becomes, a new entity), its events and drops
  # apply here; the reply tells the session how its hand changes.
  def handle_call({:interact_entity, epoch, uuid, request}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, revision}} <- Store.find(store, uuid),
         %{kind: :mob, native: ref, entity: e} = entry when ref != nil <-
           store.entries[id] || {:error, :missing_item} do
      at = {e.x, e.y, e.z}

      # A merchant trades (VMC-044b2); a bucket takes a mob over its body as
      # its record holds it.
      result =
        with :pass <- merchant_interact(state, entry, id, request),
             :pass <- bucket(entry, request),
             do: native_interaction(entry, id, request)

      case result do
        {:merchant, reply, state} ->
          {:reply, reply, state}

        {:ok, next, outcome} ->
          state = interacted(state, id, revision, at, next, outcome)
          state = free_knots(state, outcome.free)
          {:reply, {:ok, Map.take(outcome, [:hand, :swing, :others])}, state}

        other ->
          {:reply, other, state}
      end
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
      :pass -> {:reply, :pass, state}
      _ -> {:reply, {:error, :not_living}, state}
    end
  end

  # A merchant's trading, asked by its trading player's session (VMC-044b2,
  # `Region.merchant/3`): `:view`, `:stop`, `{:updated, valid}` and
  # `{:trade, index, player}`. A trade's level-up draws the next level's
  # offers; its orb drops at the merchant.
  def handle_call({:merchant, epoch, uuid, action}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{kind: :mob, native: ref, entity: e} when ref != nil <-
           store.entries[id] || {:error, :missing_item} do
      at = {e.x, e.y, e.z}

      case action do
        :view ->
          {result, state} = merchant_act(state, ref, id, :view)
          box = Valimc.Entity.NativeBody.box(store.entries[id].body, at)
          {:reply, {:ok, Map.merge(result, %{position: at, box: box})}, state}

        {:trade, index, player} ->
          case merchant_act(state, ref, id, {:trade, index, player}) do
            {%{} = traded, state} ->
              state = traded_orb(state, at, traded.pop)

              {offers, state} =
                if traded.leveled,
                  do: level_up_offers(state, ref, id, uuid, at, traded),
                  else: {traded.offers, state}

              {:reply, {:ok, %{traded | offers: offers}}, state}

            {{:error, reason}, state} ->
              {:reply, {:error, {:invalid, reason}}, state}
          end

        action when action == :stop or (is_tuple(action) and elem(action, 0) == :updated) ->
          {result, state} = merchant_act(state, ref, id, action)
          {:reply, {:ok, result}, state}
      end
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :not_merchant}, state}
    end
  end

  # A player's act this section's mobs react to (VMC-043d, `Region.mob_event/2`).
  def handle_call({:mob_event, epoch, event}, _from, state) do
    if epoch == state.epoch do
      {:reply, :ok, %{state | mob_events: Enum.take(state.mob_events ++ [event], -64)}}
    else
      {:reply, {:error, {:retry, :stale_owner}}, state}
    end
  end

  # A player's use of a fence knot (VMC-043c3, `LeashFenceKnotEntity.interact`):
  # shears snip its leads; else the player's mobs move to it, or its mobs to
  # the player; its sound plays. `{:ok, %{hand, swing, others}}` or `:pass`.
  def handle_call({:interact_knot, epoch, uuid, request}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{body: %Body{type: @knot}, entity: e} <- store.entries[id] || {:error, :missing_item} do
      pos = {floor(e.x), floor(e.y), floor(e.z)}
      mobs = leash_mobs(state)
      knot = Valimc.Entity.Leashes.knot_holder(pos, id)

      snipped =
        if Valimc.Entity.Leashes.tool(request.item) == :shears,
          do: Valimc.Entity.Leashes.snip(mobs, pos, {knot.x, knot.y + 0.25, knot.z}),
          else: []

      cond do
        not leash_ready?(state, snipped) ->
          {:reply, :pass, state}

        snipped != [] ->
          drops =
            for {mob, _, drops} <- snipped,
                {stack, _, _} <- drops,
                {^mob, %{entity: m}} <- group_entries(state),
                do: {{m.x, m.y, m.z}, stack}

          state = releash(state, for({mob, body, _} <- snipped, do: {mob, body}))

          state =
            Enum.reduce(Enum.group_by(drops, fn {at, _} -> block_section(at) end), state, fn {key,
                                                                                              drops},
                                                                                             state ->
              if key == state.key,
                do: mob_drops(state, drops),
                else: sibling_effect(state, key, {:mob_drops, drops})
            end)

          state = free_knots(state, [pos])
          Valimc.World.Sounds.play(pos, "minecraft:item.shears.snip", :player)
          {:reply, {:ok, %{hand: {:wear, 1}, swing: false, others: nil}}, state}

        true ->
          case Valimc.Entity.Leashes.knot(mobs, {pos, id}, request) do
            [] ->
              {:reply, :pass, state}

            moved ->
              if leash_ready?(state, moved) do
                state = state |> releash(moved) |> knot_sound(pos, "minecraft:item.lead.tied")

                {:reply, {:ok, %{hand: :keep, swing: false, others: nil}},
                 free_knots(state, [pos])}
              else
                {:reply, :pass, state}
              end
          end
      end
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :not_knot}, state}
    end
  end

  # A name tag on a living body (VMC-042a): named and persistent.
  def handle_call({:name_entity, epoch, uuid, name}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{kind: :mob, body: body} = entry <- store.entries[id] || {:error, :missing_item},
         true <- Valimc.Entity.Body.alive?(body) or {:error, :not_alive} do
      if Store.native_entry?(entry) do
        case Native.mob_section_name(entry.native, id, name) do
          {:ok, {_, events, {position, row}}} ->
            {:reply, :ok,
             put_entities(state, Store.native_change(store, id, position, row, events))}

          {:error, _} ->
            {:reply, {:error, :missing_item}, state}
        end
      else
        {:reply, :ok,
         put_entities(state, Store.change_body(store, id, Valimc.Entity.Body.name(body, name)))}
      end
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :not_living}, state}
    end
  end

  def handle_call({:set_entity_slot, epoch, uuid, slot, stack}, _from, state) do
    store = state.entities.store

    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         nil <- write_busy(state),
         {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{kind: :mob, body: body} = entry <- store.entries[id] || {:error, :missing_item},
         true <- Valimc.Entity.Body.alive?(body) or {:error, :not_alive} do
      if Store.native_entry?(entry) do
        case Native.mob_section_set_slot(entry.native, id, Atom.to_string(slot), stack) do
          {:ok, {true, events, {position, row}}} ->
            {:reply, :ok,
             put_entities(state, Store.native_change(store, id, position, row, events))}

          _ ->
            {:reply, {:error, :not_alive}, state}
        end
      else
        equipment =
          if stack,
            do: Map.put(body.mob.equipment, slot, stack),
            else: Map.delete(body.mob.equipment, slot)

        body = %{body | mob: %{body.mob | equipment: equipment}}
        {:reply, :ok, put_entities(state, Store.change_body(store, id, body))}
      end
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

  # Turtle eggs a player crushed (VMC-043e, `Region.crush_egg/3`).
  def handle_call({:crush_egg, epoch, cell, odds}, _from, state) do
    cond do
      epoch != state.epoch -> {:reply, Error.retry(:stale_owner), state}
      not in_region?(state, cell) -> {:reply, :ok, state}
      busy = write_busy(state) -> {:reply, {:error, busy}, state}
      true -> {:reply, :ok, crush_eggs(state, [{cell, odds}])}
    end
  end

  def handle_call({:bucket, epoch, {:release, position, empty, stack}}, _from, state) do
    with true <- epoch == state.epoch or Error.retry(:stale_owner),
         true <- in_region?(state, position) or {:error, :invalid_bucket},
         nil <- write_busy(state),
         {:ok, body} <- Valimc.Entity.Bucketable.release(stack),
         {:ok, point} <-
           Valimc.Entity.Bucketable.spawn_point(
             body.type,
             position,
             &local_or_sibling_block(state, &1)
           ),
         {:ok, id} <- Valimc.Entity.Ids.next(),
         record =
           Store.body_record(body, :crypto.strong_rand_bytes(16), point)
           |> Map.put(:entity_id, id),
         # A preflight only: a native section (VMC-081d) would keep the mob.
         {:ok, _, _} <-
           Store.create_record(%{state.entities.store | native: nil}, state.key, record) do
      case rule_run(state, %{actions: [empty]}) do
        {next, %{results: [result]}} when result > 0 ->
          # The preflight reserves only an id. Preserve all entity effects
          # of the fluid operation, then admit the animal into that store.
          {:ok, point} =
            Valimc.Entity.Bucketable.spawn_point(
              body.type,
              position,
              &local_or_sibling_block(next, &1)
            )

          random = next.ai_random || Valimc.Data.JavaRandom.create()

          {:ok, body, random} =
            Valimc.Entity.Bucketable.spawn(stack, record.uuid, point, random)

          record = Store.body_record(body, record.uuid, point) |> Map.put(:entity_id, id)
          {:ok, store, _} = Store.create_record(next.entities.store, next.key, record)
          next = put_entities(%{next | ai_random: random}, store)
          {:reply, {:ok, result}, next}

        {next, %{results: [result]}} ->
          {:reply, {:ok, result}, next}

        {next, nil} ->
          {:reply, Error.retry(:region_busy), next}
      end
    else
      {:retry, _} = busy -> {:reply, {:error, busy}, state}
      {:error, _} = error -> {:reply, error, state}
    end
  end

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
        block = Blocks.get(state.blocks, position)

        case rule_run(state, %{actions: [action]}) do
          {state, %{results: [3]}} when elem(action, 0) == :bone_meal ->
            {:reply, {:ok, 3}, pop_block_item(state, position, block)}

          {state, %{results: [index]}} when elem(action, 0) == :transform and index > 0 ->
            {:reply, {:ok, index}, transform_loot(state, action, index, block)}

          {state, %{results: [result]}} ->
            {:reply, {:ok, result}, state}

          {state, nil} ->
            {:reply, Error.retry(:region_busy), state}
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

  def handle_call({:place_block, epoch, revision, %BlockBatch{} = batch, deadline}, from, state),
    do: handle_call({:place_block, epoch, revision, batch, deadline, %{}}, from, state)

  def handle_call(
        {:place_block, epoch, revision, %BlockBatch{} = batch, deadline, fill},
        from,
        state
      ) do
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

      not valid_fill?(fill, batch) ->
        {:reply, {:error, :invalid_container_contents}, state}

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

      true ->
        start_container_blocks(state, from, batch, expected, :revision, fill: fill)
    end
  end

  # A placed shulker box's slots: 27 stacks or nil at one of the placed cells.
  defp valid_fill?(fill, batch) do
    Enum.all?(fill, fn {position, slots} ->
      Valimc.Blocks.ShulkerBox.shulker_box?(batch.edits[position]) and is_tuple(slots) and
        tuple_size(slots) == 27 and
        Enum.all?(Tuple.to_list(slots), &(is_nil(&1) or is_struct(&1, Valimc.Protocol.ItemStack)))
    end)
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
        # A creative player's break drops a filled shulker box itself
        # (`ShulkerBoxBlock.playerWillDestroy`).
        with {:ok, batch} <- BlockBatch.prepare(%{position => replacement}),
             do:
               start_container_blocks(state, from, batch, %{position => block}, :ok,
                 drop: :creative
               ),
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
    {parts, state} = take_parts(state)
    {storage, released} = RegionStorage.commit(state.storage, parts)
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

    if state.light_pending != %{} and not Jobs.running?(state.jobs, :light_frames),
      do: send_after(state, :light_retry, 0)

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

    if Valimc.World.Saving.auto?() do
      {parts, state} = take_parts(state)

      %{
        state
        | storage:
            RegionStorage.checkpoint(state.storage, parts, state.blocks,
              wait: if(opts[:detach], do: :locked, else: :written)
            )
      }
    else
      state
    end
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
    if RegionStorage.checkpoint_due?(state.storage) do
      {parts, state} = take_parts(state)

      %{
        state
        | storage:
            RegionStorage.checkpoint(state.storage, parts, state.blocks,
              wrap: &{:resource, state.epoch, &1}
            )
      }
    else
      state
    end
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
  def wait_durable(state, waits), do: commit(after_durable(state, waits))

  @doc "`waits` released once the next cut, whenever it is, is durable."
  def after_durable(state, waits) do
    %{state | storage: Enum.reduce(waits, state.storage, &RegionStorage.after_durable(&2, &1))}
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
    state = state |> retry_rule_backlog() |> retry_dispense() |> containers_changed()
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

    # Plates, buttons and tripwire check the entities on them at their ticks.
    entities =
      if Enum.any?(rule_due, fn {_, block} -> Redstone.checks?(block) end),
        do: contact_entities(state),
        else: []

    # The block rules run the due ticks, then the fluid ticks, then the
    # tick's random ticks (vanilla's `tickChunks` after `LevelTicks`) in one
    # run (VMC-081g1): lava and growing plants tick there; the draws of the
    # behaviours' states (and farmland's in wet weather) come back.
    random = random_phase(state)

    {state, outcome} =
      if rule_due == [] and fluid_due == [] and random == nil do
        {state, nil}
      else
        redstone = redstone_context(state, [], entities)

        input =
          %{ticks: rule_due, fluid_ticks: fluid_due, redstone: redstone, handling_tick: true}

        input =
          if random,
            do: %{input | redstone: Map.put(redstone, :day, day())} |> Map.put(:random, random),
            else: input

        rule_run(state, input)
      end

    drawn =
      case outcome do
        nil ->
          []

        %{drawn: drawn, grown: grown} ->
          for position <- grown, do: Valimc.World.Growth.start(state.dimension, position)
          drawn
      end

    # A behaviour claims its states before growth's rules do.
    {behaviour, farmland} = Enum.split_with(drawn, &state.tick_index[elem(&1, 1)])
    random_effects = owner_random_ticks(state, behaviour)

    state
    |> daylight_ticks(tick)
    |> farmland_ticks(farmland)
    |> apply_tick_effects(scheduled_effects ++ random_effects)
  end

  # The tick's random phase (`BlockRules.run/4`'s `random`): vanilla's
  # `randomTickSpeed` (the game rule) draws in the simulated, generated
  # chunks; lava's fire spreads only near a player (the
  # `fire_spread_radius_around_player` game rule, `canSpreadFireAround`).
  defp random_phase(%{random_tick_speed: speed}) when speed <= 0, do: nil

  defp random_phase(state) do
    mask =
      Valimc.Entity.NativeMobs.simulated_mask(
        state.key,
        Enum.reject(state.tickets.simulated, &RegionGeneration.absent?(state.generation, &1))
      )

    if mask != 0 do
      %{
        speed: min(state.random_tick_speed, 4096),
        mask: mask,
        radius: Valimc.World.GameRules.get(:fire_spread_radius_around_player),
        wet: Clock.weather().wet,
        players: for({position, _} <- state.player_targets, do: position)
      }
    end
  end

  # The overworld clock and the weather, which saplings' growth reads.
  defp day do
    weather = Clock.weather()
    {Clock.day_ticks(), weather.rain_level, weather.thunder_level}
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
          old <- [Map.get(seen, position)],
          entry !== old,
          at <- changed_container_positions(state, position, old, entry),
          uniq: true,
          do: {:output_changed, at}

    state = %{state | containers_seen: state.containers}

    if changed == [],
      do: state,
      else: elem(rule_run(state, %{actions: Enum.sort(changed)}), 0)
  end

  defp changed_container_positions(state, position, old, entry) do
    block = read_block(state, position)

    cond do
      Valimc.Blocks.Chest.ordinary?(block) and (old == nil or old.slots != entry.slots) ->
        Valimc.Blocks.Chest.positions(block, position, &local_or_sibling_block(state, &1))

      Redstone.entry_signal(old) != Redstone.entry_signal(entry) ->
        [position]

      true ->
        []
    end
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
  # Only an entity whose cells reach a chunk holding a contact block can
  # touch one, in this section or the siblings beside it its run reaches
  # (VMC-081j): the others are left out, and with none the run is skipped,
  # as a run with no work is.
  defp redstone_contacts(state) do
    reach = [state.blocks | for({_, sibling} <- neighbours(state), do: sibling.blocks)]

    case Blocks.contact_chunks(reach) do
      [] ->
        state

      chunks ->
        case contact_entities(state, if(chunks == :all, do: :all, else: MapSet.new(chunks))) do
          [] ->
            state

          entities ->
            input = %{actions: [:contacts], redstone: redstone_context(state, [], entities)}
            elem(rule_run(state, input), 0)
        end
    end
  end

  # What redstone sees of the section's entities and the players standing in
  # it: their boxes (players standing, 0.6 by 1.8) and kinds, in that order.
  # Spectators are not among the targets. `chunks`: `:all`, or the chunks
  # an entity's cells must reach to be seen.
  defp contact_entities(state, chunks \\ :all) do
    players =
      for {{x, y, z}, _} <- state.player_targets,
          Grid.region_key(Grid.chunk_key(floor(x), floor(z))) == state.key,
          box = {{x - 0.3, y, z - 0.3}, {x + 0.3, y + 1.8, z + 0.3}, :living},
          reaches?(box, chunks),
          do: box

    store = state.entities.store

    others =
      for {_, entry} <- store.entries,
          not Store.native_entry?(entry),
          box = Redstone.entity_box(entry),
          reaches?(box, chunks),
          do: box

    # The native mobs' boxes, packed by their section (VMC-081d).
    natives =
      case store.native do
        %{ref: ref} ->
          case Native.mob_section_contacts(
                 ref,
                 if(chunks == :all, do: :all, else: MapSet.to_list(chunks))
               ) do
            {0, _} -> []
            {n, packed} -> [{:packed, n, packed}]
          end

        nil ->
          []
      end

    players ++ others ++ natives
  end

  # Whether the cells a box touches (less 1e-5 each way, as the contacts
  # read them) reach one of `chunks`.
  defp reaches?(_box, :all), do: true

  defp reaches?({{x0, _, z0}, {x1, _, z1}, _}, chunks) do
    chunk = fn v -> Bitwise.bsr(floor(v), 4) end
    {cx0, cx1} = {chunk.(x0 + 1.0e-5), chunk.(x1 - 1.0e-5)}
    {cz0, cz1} = {chunk.(z0 + 1.0e-5), chunk.(z1 - 1.0e-5)}
    Enum.any?(cx0..cx1//1, fn cx -> Enum.any?(cz0..cz1//1, &MapSet.member?(chunks, {cx, &1})) end)
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

  # The comparators' outputs within the rules' reach (this section and those
  # beside it), and the signals of the containers one or two cells beside
  # them (VMC-048a: what a comparator reads, also through a conductor).
  defp comparator_context(state) do
    sections =
      [{state.key, state.comparators, state.containers}] ++
        for {key, peer} <- neighbours(state),
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
              do: {position, chest_signal(state, position, entry)}

        {outputs, containers}
    end
  end

  defp chest_signal(state, position, entry) do
    case joined_chest(state, position) do
      {:ok, view} -> Redstone.entry_signal(view)
      _ -> Redstone.entry_signal(entry)
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

  # Farmland's random draws in wet weather (VMC-039a): its tick reads the
  # rain above it (`Growth.random_ticks/2`), so it runs here after the
  # tick's run.
  defp farmland_ticks(state, []), do: state

  defp farmland_ticks(state, hits) do
    actions = Valimc.World.Growth.random_ticks(state.dimension, hits)
    context = state |> redstone_context([], []) |> Map.put(:day, day())

    {state, outcome} =
      rule_run(state, %{actions: actions, redstone: context, handling_tick: true})

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
      entries = Map.new(ready, &{&1, RegionGeneration.post_entry(state.post[&1])})
      marks = for chunk <- ready, {x, y, z} <- elem(entries[chunk], 0), do: {x, y, z}
      actions = for position <- marks, do: {:post, position}
      {state, outcome} = rule_run(state, %{actions: actions, handling_tick: true})

      kept =
        if outcome,
          do: for({position, 0} <- Enum.zip(marks, outcome.results), do: position),
          else: marks

      ticks =
        for chunk <- ready,
            {position, name} <- elem(entries[chunk], 1),
            do: {:schedule, position, {:fluid, Valimc.Blocks.Fluids.id(name)}, 0, 0}

      kept_by_chunk = Enum.group_by(kept, fn {x, _, z} -> Grid.chunk_key(x, z) end)

      post =
        Enum.reduce(ready, state.post, fn chunk, acc ->
          case kept_by_chunk do
            # Unchanged marks stay the same term (the storage compares by
            # identity first).
            %{^chunk => marks} ->
              if acc[chunk] == {marks, []}, do: acc, else: Map.put(acc, chunk, {marks, []})

            _ ->
              Map.delete(acc, chunk)
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
        sibling = state.siblings[key] -> not MapSet.member?(sibling.absent_set, chunk)
        true -> false
      end
    end)
  end

  # The behaviours' random ticks at the draws the run returned (turtle eggs,
  # budding amethyst): their effects.
  defp owner_random_ticks(_state, []), do: []

  defp owner_random_ticks(state, hits) do
    read = &read_block(state, &1)
    context = tick_context(state)

    for {position, block} <- hits,
        module = state.tick_index[block],
        effect <- random_tick(module, position, block, read, context),
        do: effect
  end

  defp random(bound), do: :rand.uniform(bound) - 1

  # A behaviour's random tick, with the region's context where it takes one.
  defp random_tick(module, position, block, read, context) do
    if function_exported?(module, :random_tick, 5),
      do: module.random_tick(position, block, read, &random/1, context),
      else: module.random_tick(position, block, read, &random/1)
  end

  # What behaviours' random ticks read of the world (VMC-043e: the turtle
  # egg hatch chance of this dimension's clock now).
  defp tick_context(state) do
    dimension = Valimc.World.Dimension.name(state.dimension)

    %{
      hatch_chance:
        Valimc.World.Spawning.turtle_hatch_chance(dimension, Valimc.World.Clock.day_ticks())
    }
  end

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
    work = Map.drop(input, [:redstone, :actor, :handling_tick])

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
          context
          |> Map.update(
            :pending,
            [],
            &(&1 ++ change_pending(state, Map.get(input, :changes, %{})))
          )
          |> Map.put(:pistons, piston_context(state, input))
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

        # A random phase is not retried: its draws are this tick's.
        busy ->
          {%{state | rule_backlog: [Map.delete(input, :random) | state.rule_backlog]}, nil}

        true ->
          {own, theirs} = Map.pop(parts, state.key)

          state = %{
            state
            | torch_toggles: outcome.toggles,
              block_events: outcome.pending_events,
              piston_order: next_piston_order(outcome.pistons, state.piston_order)
          }

          state = play_redstone(state, outcome, input)
          state = if own, do: apply_rules(state, own), else: state
          effects = for {key, part} <- theirs, do: {key, {:rules, part}}
          {%{state | sibling_effects: state.sibling_effects ++ effects}, outcome}
      end
    end
  end

  # What pistons read in a run (VMC-048b): the section's pending block events,
  # whether the run is the tick's block event phase and in its first part
  # (`isHandlingTick`: block, random and chunk ticks and block events), the
  # tick order its new moving pistons take, the border and build height.
  defp piston_context(state, input) do
    {min_y, height} = Valimc.World.Dimension.bounds(state.dimension)

    %{
      events: state.block_events,
      run_events: Map.has_key?(input, :block_events),
      handling_tick: Map.get(input, :handling_tick, false),
      order: state.piston_order,
      border:
        case Valimc.Physics.BorderSnapshot.bounds(Clock.border_snapshot(state.dimension)) do
          {:ok, bounds} -> bounds
          {:error, _} -> {-3.0e7, -3.0e7, 3.0e7, 3.0e7}
        end,
      build: {min_y, min_y + height - 1}
    }
  end

  # The next tick order after the moving pistons `pistons` and `from`.
  defp next_piston_order(pistons, from \\ 0) do
    Enum.reduce(pistons, from, fn
      {_, {_, _, _, _, _, _, _, order}}, acc -> max(acc, order + 1)
      _, acc -> acc
    end)
  end

  @doc """
  The tick's block event phase (VMC-048b, `ServerLevel.runBlockEvents`): the
  pending block events run in order, those they raise too, after the block
  ticks.
  """
  def block_events(%{block_events: []} = state), do: state

  def block_events(state) do
    if Tickets.simulating?(state.tickets),
      do: elem(rule_run(state, %{block_events: true, handling_tick: true}), 0),
      else: state
  end

  @doc """
  Moving pistons' block entities tick (VMC-048b, `PistonMovingBlockEntity.tick`)
  after the entities, in the order they were made, in the chunks that tick:
  each advances half a block (moving the entities it meets) or lands as its
  block.
  """
  def moving_pistons(%{pistons: pistons} = state) when map_size(pistons) == 0, do: state

  def moving_pistons(state) do
    actions =
      for {{x, _, z} = position, _} <- Enum.sort_by(state.pistons, &elem(elem(&1, 1), 7)),
          Tickets.simulated?(state.tickets, Grid.chunk_key(x, z)),
          do: {:moving, position}

    if actions == [] do
      state
    else
      {state, outcome} = rule_run(state, %{actions: actions})
      if outcome, do: push_entities(state, outcome.pushes), else: state
    end
  end

  @doc """
  The section's hoppers for this tick (VMC-049a, `Valimc.World.Hoppers`), in
  the chunks that simulate: their containers, the containers they reach and
  the items they take change in this commit, together or not at all. Inserts
  into a sibling section's containers go to it as a sibling effect, applied
  before the group's next cut. While a plan holds the item store the hoppers
  see no item entities.
  """
  def hoppers(%{containers: %{entries: entries}} = state) when map_size(entries) == 0,
    do: state

  def hoppers(state) do
    hoppers =
      for {{x, _, z} = position, %{kind: :hopper, order: order}} <- state.containers.entries,
          Tickets.simulated?(state.tickets, Grid.chunk_key(x, z)),
          do: {order, position}

    if hoppers == [],
      do: state,
      else: run_hoppers(state, Enum.map(Enum.sort(hoppers), &elem(&1, 1)))
  end

  defp run_hoppers(state, hoppers) do
    entries = state.containers.entries

    result =
      Valimc.World.Hoppers.tick(%{
        tick: state.game_tick,
        entries: entries,
        foreign: hopper_foreign(state, hoppers),
        block: &hopper_block(state, &1),
        items: hopper_items(state, hoppers),
        hoppers: hoppers,
        ticked: state.hopper_ticked
      })

    ticked = Map.take(result.ticked, Map.keys(entries))

    with {:ok, effects} <- plan_foreign_containers(state, result.foreign),
         {:ok, store} <- take_hopper_items(state.entities.store, result.items),
         {:ok, containers, content} <- put_container_entries(state.containers, result.entries) do
      state = %{
        state
        | containers: containers,
          hopper_ticked: ticked,
          sibling_effects: state.sibling_effects ++ effects
      }

      state = if result.items == %{}, do: state, else: put_entities(state, store)
      containers_moved(state, content)
    else
      _ ->
        Valimc.Data.Metrics.add(:hopper_refused)
        %{state | hopper_ticked: ticked}
    end
  end

  # Dispensers and droppers whose tick fired (VMC-049a, `DispenserBlock.
  # dispenseFrom`), in order; while a plan holds the item store they wait
  # for the next block phase, so what they make or take is never lost.
  defp dispense(state, []), do: state

  defp dispense(state, cells) do
    if planning?(state),
      do: %{state | dispense_backlog: state.dispense_backlog ++ cells},
      else: Enum.reduce(cells, state, &dispense_from(&2, &1))
  end

  defp retry_dispense(%{dispense_backlog: []} = state), do: state

  defp retry_dispense(state) do
    if planning?(state),
      do: state,
      else: dispense(%{state | dispense_backlog: []}, state.dispense_backlog)
  end

  defp dispense_from(state, position) do
    block = read_block(state, position)
    kind = Valimc.Blocks.Machine.kind(block)

    case state.containers.entries[position] do
      %{kind: ^kind, slots: slots} = entry when kind in [:dropper, :dispenser] ->
        step = Valimc.Blocks.Machine.facing(block)

        case Valimc.Blocks.Dispensing.random_slot(slots, &(:rand.uniform(&1) - 1)) do
          nil ->
            dispense_events(state, [{position, 1001, 0}])

          slot when kind == :dropper ->
            drop_into(state, position, entry, slot, step)

          slot ->
            stack = elem(slots, slot)
            behaviour = Valimc.Blocks.Dispensing.behaviour(stack)
            dispense_item(state, behaviour, position, entry, slot, step)
        end

      _ ->
        state
    end
  end

  # `DropperBlock.dispenseFrom`: one item into the container in front (a
  # sibling section's too), else dropped.
  defp drop_into(state, {x, y, z} = position, entry, slot, {dx, dy, dz} = step) do
    stack = elem(entry.slots, slot)
    target = {x + dx, y + dy, z + dz}

    side =
      Map.fetch!(
        %{
          {0, 1, 0} => :down,
          {0, -1, 0} => :up,
          {0, 0, 1} => :north,
          {0, 0, -1} => :south,
          {1, 0, 0} => :west,
          {-1, 0, 0} => :east
        },
        step
      )

    one = %{stack | count: 1}

    case dropper_target(state, target) do
      nil ->
        dispense_item(state, :drop, position, entry, slot, step)

      {:joined, key, target_entry, target_block} ->
        case Valimc.Blocks.ItemTransfer.add(target_entry, one, side, target_block) do
          {_next, nil, _} ->
            entries =
              Map.put(state.containers.entries, position, %{
                entry
                | slots: put_elem(entry.slots, slot, shrink(stack))
              })

            case put_container_entries(state.containers, entries) do
              {:ok, containers, content} ->
                state = containers_moved(%{state | containers: containers}, content)

                %{
                  state
                  | sibling_effects:
                      state.sibling_effects ++
                        [{key, {:hopper_inserts, [{target, one, side, nil}]}}]
                }

              _ ->
                state
            end

          _ ->
            state
        end

      {:own, target_entry, target_block} ->
        case Valimc.Blocks.ItemTransfer.add(target_entry, one, side, target_block) do
          {next, nil, woke} ->
            next =
              if woke and match?(%{kind: :hopper}, next),
                do: Valimc.Blocks.ItemTransfer.woken_cooldown(next, false),
                else: next

            entries =
              state.containers.entries
              |> Map.put(target, next)
              |> Map.put(position, %{entry | slots: put_elem(entry.slots, slot, shrink(stack))})

            commit_dispenser_entries(state, entries)

          _ ->
            state
        end

      {:sibling, key, target_entry, target_block} ->
        case Valimc.Blocks.ItemTransfer.add(target_entry, one, side, target_block) do
          {_next, nil, _woke} ->
            entries =
              Map.put(state.containers.entries, position, %{
                entry
                | slots: put_elem(entry.slots, slot, shrink(stack))
              })

            state = commit_dispenser_entries(state, entries)
            effect = {key, {:hopper_inserts, [{target, one, side, nil}]}}
            %{state | sibling_effects: state.sibling_effects ++ [effect]}

          _ ->
            state
        end
    end
  end

  defp dropper_target(state, {x, _, z} = target) do
    block = hopper_block(state, target)
    key = Grid.region_key(Grid.chunk_key(x, z))

    entry =
      if key == state.key,
        do: state.containers.entries[target],
        else: get_in(state.siblings, [key, :containers]) |> then(&(&1 && &1.entries[target]))

    cond do
      block == nil or entry == nil or not container_matches?(entry, block) ->
        nil

      Valimc.Blocks.Chest.ordinary?(block) and not Valimc.Blocks.Chest.single?(block) ->
        case joined_chest(state, target) do
          {:ok, view} -> {:joined, key, view, block}
          _ -> nil
        end

      key == state.key ->
        {:own, entry, block}

      true ->
        {:sibling, key, entry, block}
    end
  end

  defp container_matches?(%{cooking: _, kind: kind}, block),
    do: Valimc.Blocks.CookingBlocks.kind(block) == kind

  defp container_matches?(%{rows: 3}, block), do: Valimc.Blocks.block_entity(block) == :chest

  defp container_matches?(%{kind: kind, slots: _}, block),
    do: Valimc.Blocks.block_entity(block) == kind

  defp container_matches?(_, _), do: false

  defp shrink(%{count: 1}), do: nil
  defp shrink(stack), do: %{stack | count: stack.count - 1}

  # A dispenser's behaviour for the stack in `slot` (`DispenseItemBehavior.
  # dispense`): its effect, then its sound and smoke.
  defp dispense_item(state, :drop, position, entry, slot, step) do
    stack = elem(entry.slots, slot)
    state = put_dispenser_slot(state, position, entry, slot, shrink(stack))

    state
    |> spawn_dispensed(position, step, %{stack | count: 1})
    |> dispensed_events(position, step, 1000)
  end

  defp dispense_item(state, {:projectile, config}, position, entry, slot, step) do
    stack = elem(entry.slots, slot)
    body = Projectile.new(config.entity, nil, stack)

    # `ArrowItem.asProjectile`: a dispensed arrow may be picked up.
    body =
      if config.entity == "minecraft:arrow",
        do: %{body | data: %{body.data | pickup: :allowed}},
        else: body

    body = Projectile.shoot(body, step, config.power, config.uncertainty)
    at = Valimc.Blocks.Dispensing.launch(position, step, config)
    record = Store.body_record(body, :crypto.strong_rand_bytes(16), at)

    state
    |> put_dispenser_slot(position, entry, slot, shrink(stack))
    |> adopt_dispensed([record])
    |> dispensed_events(position, step, config.event)
  end

  defp dispense_item(state, :tnt, {x, y, z} = position, entry, slot, {dx, dy, dz} = step) do
    if Valimc.World.GameRules.get(:tnt_explodes) do
      target = {x + dx, y + dy, z + dz}
      stack = elem(entry.slots, slot)
      Valimc.World.Sounds.play(target, "minecraft:entity.tnt.primed", :block)

      state
      |> put_dispenser_slot(position, entry, slot, shrink(stack))
      |> adopt_dispensed([Explosion.primed_record(target, 80)])
      |> dispensed_events(position, step, 1000)
    else
      dispensed_events(state, position, step, 1001)
    end
  end

  # A water or lava bucket pours in front (`BucketItem.emptyContents`, no
  # player); one that cannot drops as an item instead.
  defp dispense_item(
         state,
         {:pour, fluid},
         {x, y, z} = position,
         _entry,
         slot,
         {dx, dy, dz} = step
       ) do
    target = {x + dx, y + dy, z + dz}

    case rule_run(state, %{actions: [{:empty, target, fluid, nil, false}]}) do
      {state, %{results: [result]}} when result > 0 ->
        entry = state.containers.entries[position]

        state =
          with_remainder(
            state,
            position,
            entry,
            slot,
            Valimc.Protocol.ItemStack.new("bucket"),
            step
          )

        dispensed_events(state, position, step, 1000)

      {state, _} ->
        entry = state.containers.entries[position]

        state
        |> dispense_item(:drop, position, entry, slot, step)
        |> dispensed_events(position, step, 1000)
    end
  end

  # An empty bucket fills from what is in front (`BucketPickup.pickupBlock`).
  defp dispense_item(state, :fill, {x, y, z} = position, _entry, slot, {dx, dy, dz} = step) do
    target = {x + dx, y + dy, z + dz}

    case rule_run(state, %{actions: [{:pickup, target}]}) do
      {state, %{results: [result]}} when result > 0 ->
        filled = Valimc.Protocol.ItemStack.new(Valimc.Blocks.Fluids.pickup_item(result))
        entry = state.containers.entries[position]
        state = with_remainder(state, position, entry, slot, filled, step)
        dispensed_events(state, position, step, 1000)

      {state, _} ->
        dispense_item(state, :drop, position, state.containers.entries[position], slot, step)
    end
  end

  # Bone meal on what is in front (`BoneMealItem.growCrop`, else
  # `growWaterPlant`): the generator's growth grows in a task; it fails on
  # anything else.
  defp dispense_item(state, :bone_meal, {x, y, z} = position, _entry, slot, {dx, dy, dz} = step) do
    target = {x + dx, y + dy, z + dz}
    block = read_block(state, target)
    corals = Valimc.World.Growth.corals?(state.dimension, target)
    action = {:bone_meal, target, nil, corals}

    case rule_run(state, %{actions: [action]}) do
      {state, %{results: [result]} = outcome} when result > 0 ->
        Valimc.World.Growth.grow(state.dimension, [action], outcome)
        entry = state.containers.entries[position]
        stack = elem(entry.slots, slot)
        state = put_dispenser_slot(state, position, entry, slot, shrink(stack))
        state = if result == 3, do: pop_block_item(state, target, block), else: state
        state |> dispense_events([{target, 1505, 15}]) |> dispensed_events(position, step, 1000)

      {state, _} ->
        dispensed_events(state, position, step, 1001)
    end
  end

  # Armour and other dispensable equipment goes on the first mob in front
  # that can wear it and picks up loot (`dispenseEquipment`); else it drops.
  # Players in front are not dressed yet: it drops for them too.
  defp dispense_item(state, :equipment, {x, y, z} = position, entry, slot, {dx, dy, dz} = step) do
    stack = elem(entry.slots, slot)
    cell = {x + dx, y + dy, z + dz}

    name = Valimc.Protocol.ItemTypes.item(stack.item_id)["name"]

    case dressed(state.entities.store, cell, stack, name) do
      {:ok, store} ->
        state
        |> put_dispenser_slot(position, entry, slot, shrink(stack))
        |> put_entities(store)
        |> dispensed_events(position, step, 1000)

      :none ->
        dispense_item(state, :drop, position, entry, slot, step)
    end
  end

  defp dispense_item(state, :unsupported, position, _entry, _slot, step),
    do: dispensed_events(state, position, step, 1001)

  # The first mob (by id) whose box holds the cell and whose type may wear
  # the item, that wears it (its section's `mob_section_equip/4`: a living
  # mob that picks up loot, the slot empty).
  defp dressed(store, {cx, cy, cz}, stack, name) do
    with {slot, types} <- Valimc.Data.HostileFacts.equippable(name) do
      store.entries
      |> Enum.sort()
      |> Enum.find_value(:none, fn
        {id, %{kind: :mob, native: ref, body: %NativeBody{type: type}} = entry} when ref != nil ->
          with {{x0, y0, z0}, {x1, y1, z1}, _} <- Redstone.entity_box(entry),
               true <- types == nil or type in types,
               true <-
                 x1 > cx and x0 < cx + 1 and y1 > cy and y0 < cy + 1 and z1 > cz and z0 < cz + 1,
               {:ok, {true, events, {position, row}}} <-
                 Native.mob_section_equip(ref, id, Atom.to_string(slot), %{stack | count: 1}) do
            {:ok, Store.native_change(store, id, position, row, events)}
          else
            _ -> nil
          end

        _ ->
          nil
      end)
    else
      _ -> :none
    end
  end

  # `consumeWithRemainder`: the stack shrinks; a last one becomes the
  # remainder, else the remainder goes into the dispenser or drops.
  defp with_remainder(state, position, entry, slot, remainder, step) do
    stack = elem(entry.slots, slot)

    case shrink(stack) do
      nil ->
        put_dispenser_slot(state, position, entry, slot, remainder)

      left ->
        slots = put_elem(entry.slots, slot, left)
        {slots, rest} = Valimc.Blocks.Dispensing.insert(slots, remainder)
        entries = Map.put(state.containers.entries, position, %{entry | slots: slots})
        state = commit_dispenser_entries(state, entries)

        if rest,
          do:
            state
            |> spawn_dispensed(position, step, rest)
            |> dispensed_events(position, step, 1000),
          else: state
    end
  end

  defp put_dispenser_slot(state, position, entry, slot, stack) do
    entries =
      Map.put(state.containers.entries, position, %{
        entry
        | slots: put_elem(entry.slots, slot, stack)
      })

    commit_dispenser_entries(state, entries)
  end

  defp commit_dispenser_entries(state, entries) do
    case put_container_entries(state.containers, entries) do
      {:ok, containers, content} -> containers_moved(%{state | containers: containers}, content)
      {:error, _} -> state
    end
  end

  # `spawnItem`: one item out of the front, with its random push.
  defp spawn_dispensed(state, position, step, stack) do
    {{x, y, z}, velocity} = Valimc.Blocks.Dispensing.drop(position, step, &:rand.uniform/0)

    record = %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x,
      y: y,
      z: z,
      stack: stack,
      motion: %Valimc.Entity.ItemMotionState{velocity: velocity, pickup_delay: 0}
    }

    adopt_dispensed(state, [record])
  end

  defp adopt_dispensed(state, records) do
    if planning?(state),
      do: %{state | entities: %{state.entities | dropped: state.entities.dropped ++ records}},
      else: adopt_drops(state, records)
  end

  # Its sound (`event`) and its smoke toward its front (`playAnimation`).
  defp dispensed_events(state, position, step, event),
    do:
      dispense_events(state, [
        {position, event, 0},
        {position, 2000, Valimc.Blocks.Dispensing.face(step)}
      ])

  defp dispense_events(state, events), do: release_effect(state, {:level_events, events})

  # A sibling section's hoppers' inserts into this section's containers
  # (VMC-049a); what no longer fits drops at the container, never lost.
  defp hopper_inserts(state, [{target, stack, side, _}] = inserts) do
    case joined_chest(state, target) do
      {:ok, view} ->
        {view, rest, _} =
          Valimc.Blocks.ItemTransfer.add(view, stack, side, hopper_block(state, target))

        updates =
          Map.new(Containers.chest_parts(view), fn {at, slots} ->
            {at, %{container_entry(state, at) | slots: slots}}
          end)

        {own, foreign} =
          Enum.split_with(updates, fn {at, _} -> route_of(state, at) == state.key end)

        with {:ok, effects} <- plan_foreign_containers(state, Map.new(foreign)),
             {:ok, containers, content} <- put_container_entries(state.containers, Map.new(own)) do
          state =
            containers_moved(
              %{
                state
                | containers: containers,
                  sibling_effects: state.sibling_effects ++ effects
              },
              content
            )

          spill_hopper_items(state, if(rest, do: [{target, rest}], else: []))
        else
          _ -> spill_hopper_items(state, [{target, stack}])
        end

      _ ->
        plain_hopper_inserts(state, inserts)
    end
  end

  defp hopper_inserts(state, inserts), do: plain_hopper_inserts(state, inserts)

  defp plain_hopper_inserts(state, inserts) do
    {entries, spilled} =
      Valimc.World.Hoppers.receive(
        state.containers.entries,
        inserts,
        &hopper_block(state, &1),
        state.hopper_ticked
      )

    {state, spilled} =
      case put_container_entries(state.containers, entries) do
        {:ok, containers, content} ->
          {containers_moved(%{state | containers: containers}, content), spilled}

        {:error, _} ->
          {state, for({position, stack, _, _} <- inserts, do: {position, stack})}
      end

    spill_hopper_items(state, spilled)
  end

  defp spill_hopper_items(state, spilled) do
    records =
      for {{x, y, z}, stack} <- spilled,
          do: %{
            uuid: :crypto.strong_rand_bytes(16),
            x: x + 0.5,
            y: y + 0.5,
            z: z + 0.5,
            stack: stack
          }

    cond do
      records == [] ->
        state

      planning?(state) ->
        %{state | entities: %{state.entities | dropped: state.entities.dropped ++ records}}

      true ->
        adopt_drops(state, records)
    end
  end

  # The block at a position for the hoppers: this section's or a sibling's,
  # nil where not generated or outside the group.
  defp hopper_block(state, {x, y, z} = position) do
    chunk = Grid.chunk_key(x, z)

    case Grid.region_key(chunk) do
      key when key == state.key ->
        read_block(state, position)

      key ->
        with %{blocks: blocks, absent_set: absent} <- state.siblings[key],
             false <- MapSet.member?(absent, chunk),
             true <- Chunk.valid_y?(y),
             do: Blocks.get(blocks, position),
             else: (_ -> nil)
    end
  end

  # The containers of sibling sections the hoppers face.
  defp hopper_foreign(state, hoppers) do
    for {x, y, z} = position <- hoppers,
        block = read_block(state, position),
        block != nil,
        {dx, dy, dz} = Valimc.Blocks.Machine.facing(block),
        target <- [{x + dx, y + dy, z + dz}, {x, y + 1, z}],
        target_block = hopper_block(state, target),
        target_block != nil,
        at <- Valimc.Blocks.Chest.positions(target_block, target, &hopper_block(state, &1)),
        key = route_of(state, at),
        key != state.key,
        entry = container_entry(state, at),
        entry != nil,
        into: %{},
        do: {at, entry}
  end

  defp container_entry(state, at) do
    case route_of(state, at) do
      key when key == state.key ->
        state.containers.entries[at]

      key ->
        with %{containers: containers} <- state.siblings[key],
             do: containers.entries[at],
             else: (_ -> nil)
    end
  end

  defp joined_chest(state, at) do
    with block when is_integer(block) <- hopper_block(state, at),
         true <- Valimc.Blocks.Chest.ordinary?(block),
         [_, _] = parts <- Valimc.Blocks.Chest.positions(block, at, &hopper_block(state, &1)),
         do: Containers.chest_view(parts, &container_entry(state, &1)),
         else: (_ -> :none)
  end

  # Sibling effects are applied between phases by the group, before another
  # container action can run. Plan every replacement before adopting any.
  defp plan_foreign_containers(state, entries) do
    entries
    |> Enum.group_by(fn {at, _} -> route_of(state, at) end)
    |> Enum.reduce_while({:ok, []}, fn {key, entries}, {:ok, effects} ->
      original = state.siblings[key].containers

      case put_container_entries(original, Map.new(entries)) do
        {:ok, ^original, []} ->
          {:cont, {:ok, effects}}

        {:ok, next, content} ->
          {:cont, {:ok, effects ++ [{key, {:container_entries, original, next, content}}]}}

        error ->
          {:halt, error}
      end
    end)
  end

  # The items near the hoppers, in entity order, in chunks that simulate;
  # none while a plan holds the store.
  defp hopper_items(state, hoppers) do
    if planning?(state) do
      []
    else
      columns = MapSet.new(hoppers, fn {x, _, z} -> {x, z} end)
      corners = [{-0.125, -0.125}, {-0.125, 0.125}, {0.125, -0.125}, {0.125, 0.125}]

      # An item over a column stands within a block of it: the chunks
      # around the columns hold every candidate (VMC-081l).
      chunks =
        for {x, z} <- columns,
            dx <- [-1, 1],
            dz <- [-1, 1],
            uniq: true,
            do: Grid.chunk_key(x + dx, z + dz)

      near =
        for {id, %{entity: %{x: x, y: y, z: z}, stack: stack}} <-
              Store.in_chunks(state.entities.store, chunks, :item),
            Enum.any?(corners, fn {dx, dz} ->
              MapSet.member?(columns, {floor(x + dx), floor(z + dz)})
            end),
            Tickets.simulated?(state.tickets, Grid.chunk_key(floor(x), floor(z))),
            do: %{id: id, x: x, y: y, z: z, stack: stack}

      Enum.sort_by(near, & &1.id)
    end
  end

  # Items the hoppers took: what is left of each (nil: all of it).
  defp take_hopper_items(store, taken) do
    Enum.reduce_while(taken, {:ok, store}, fn {id, stack}, {:ok, store} ->
      result =
        case store.entries[id] do
          %{kind: :item, revision: revision} when stack == nil ->
            Store.remove(store, store.epoch, id, revision)

          %{kind: :item, revision: revision} ->
            with {:ok, next, _} <- Store.replace(store, store.epoch, id, revision, stack),
                 do: {:ok, next}

          _ ->
            {:error, :missing_item}
        end

      case result do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
  end

  # Container entries a tick moved items through, against the owner's: their
  # slots under a new revision, a hopper's cooldown alone under the same.
  # Returns the positions whose contents changed.
  defp put_container_entries(containers, entries) do
    Enum.reduce_while(entries, {:ok, containers, []}, fn {position, entry}, {:ok, acc, content} ->
      old = acc.entries[position]

      result =
        cond do
          entry == old ->
            {:ok, acc, content}

          match?(%{cooking: _}, entry) ->
            with {:ok, next, _} <-
                   Containers.replace_cooking(
                     acc,
                     position,
                     old.revision,
                     entry.cooking,
                     entry.recipes
                   ),
                 do: {:ok, next, [position | content]}

          entry.slots != old.slots ->
            with {:ok, next, replaced} <-
                   Containers.replace(acc, position, old.revision, entry.slots),
                 {:ok, next} <- put_cooldown(next, position, replaced.revision, entry),
                 do: {:ok, next, [position | content]}

          true ->
            with {:ok, next} <- put_cooldown(acc, position, old.revision, entry),
                 do: {:ok, next, content}
        end

      case result do
        {:ok, _, _} = ok -> {:cont, ok}
        error -> {:halt, error}
      end
    end)
  end

  defp put_cooldown(containers, position, revision, %{cooldown: cooldown}),
    do: Containers.put_cooldown(containers, position, revision, cooldown)

  defp put_cooldown(containers, _position, _revision, _entry), do: {:ok, containers}

  # Viewers and permits learn of containers whose contents moved.
  defp containers_moved(state, []), do: state

  defp containers_moved(state, content) do
    state = %{
      state
      | permits:
          Permits.invalidate(state.permits, Map.new(content, &{&1, nil}), [:mining, :placement])
    }

    release_now(state, Enum.map(Enum.reverse(content), &{:container_changed, &1}))
  end

  # Moving blocks' pushes (VMC-048b) on the entities this section holds, its
  # sibling sections' and the group's players near them (each owner pushes
  # its own, as `moveCollidedEntities` and `moveStuckEntities` do).
  defp push_entities(state, []), do: state

  defp push_entities(state, pushes) do
    effects =
      for({key, _} <- state.siblings, key != state.key, do: {key, {:piston_pushes, pushes}}) ++
        [{:players, {:piston_pushes, state.dimension, pushes}}]

    push_own(%{state | sibling_effects: state.sibling_effects ++ effects}, pushes)
  end

  # Pushes reach a body within a few blocks of the moving block.
  defp push_reach?(pushes, {x, y, z}) do
    Enum.any?(pushes, fn {{px, py, pz}, _, _, _, landed} ->
      not landed and
        abs(x - px - 0.5) <= 4.0 and abs(y - py - 0.5) <= 5.0 and abs(z - pz - 0.5) <= 4.0
    end)
  end

  defp push_own(state, pushes) do
    candidates =
      for {id, %{entity: %{x: x, y: y, z: z}} = entry} <- Enum.sort(state.entities.store.entries),
          push_reach?(pushes, {x, y, z}),
          body = push_body(entry),
          body != nil,
          do: {id, entry, body}

    if candidates == [] or write_busy(state) != nil do
      state
    else
      {:ok, results} =
        Valimc.Physics.Kernel.pistons(
          Valimc.World.View.new(state.dimension),
          pushes,
          for({_, _, body} <- candidates, do: body),
          Clock.border_snapshot(state.dimension)
        )

      moved =
        for {{id, entry, _}, {feet, velocity, on_ground, true}} <- Enum.zip(candidates, results),
            do: {id, entry, feet, velocity, on_ground}

      commit_displaced(state, moved)
    end
  end

  defp commit_displaced(state, moved) do
    {items, bodies} = Enum.split_with(moved, fn {_, e, _, _, _} -> e.kind in [:item, :orb] end)

    item_steps =
      for {id, entry, feet, velocity, on_ground} <- items,
          do: %{
            id: id,
            revision: entry.revision,
            physical_revision: entry.physical_revision,
            position: feet,
            motion: %{entry.motion | velocity: velocity, on_ground: on_ground}
          }

    state =
      if item_steps == [], do: state, else: elem(commit_simulated_items(state, item_steps), 1)

    body_steps =
      for {id, entry, feet, velocity, on_ground} <- bodies,
          do: %{
            id: id,
            revision: entry.revision,
            position: feet,
            body: %{entry.body | velocity: velocity, on_ground: on_ground}
          }

    route_bodies(state, body_steps)
  end

  # The live mob phase already moved its local targets. Other stores and
  # hosted players receive the same external effect through the group.
  defp push_lid(state, {area, delta, local} = push) do
    effects =
      for({key, _} <- state.siblings, key != state.key, do: {key, {:shulker_push, push}}) ++
        [{:players, {:shulker_push, state.dimension, area, delta}}]

    displace_own(
      %{state | sibling_effects: state.sibling_effects ++ effects},
      {area, delta, local}
    )
  end

  defp displace_own(state, {area, delta, local}) do
    exclude = MapSet.new(local)
    entries = group_entries(state)
    view = Valimc.World.View.new(state.dimension)
    border = Clock.border_snapshot(state.dimension)

    moved =
      if write_busy(state) == nil do
        for {id, entry} <- Enum.sort(state.entities.store.entries),
            not MapSet.member?(exclude, id),
            Valimc.Entity.Displacement.meets?(entry, area),
            {:ok, boxes} <- [Valimc.Entity.Displacement.colliders(entries, entry, delta)],
            {:ok, {feet, velocity, on_ground}} <-
              [
                Valimc.Physics.Kernel.displace(
                  view,
                  Valimc.Entity.Displacement.input(entry),
                  delta,
                  boxes,
                  border
                )
              ],
            do: {id, entry, feet, velocity, on_ground}
      else
        []
      end

    commit_displaced(state, moved)
  end

  # What a push reads of an entity (VMC-048b): its box, motion, step height,
  # whether the server simulates it (all but players), its push reaction (an
  # effect cloud's is `IGNORE_ENTITY`), bounce and gravity.
  defp push_body(%{kind: kind, entity: %{x: x, y: y, z: z}, motion: motion})
       when kind in [:item, :orb] do
    {half, height, gravity} =
      if kind == :item, do: {0.125, 0.25, 0.04}, else: {0.25, 0.5, 0.03}

    gravity = if motion.no_gravity, do: 0.0, else: gravity

    {{x * 1.0, y * 1.0, z * 1.0}, {half, height}, motion.velocity,
     {motion.on_ground, 0.0, true, false}, {0.0, false, false, gravity, 0.98}}
  end

  # A mob (VMC-081d) from its row.
  defp push_body(%{
         kind: :mob,
         entity: %{x: x, y: y, z: z},
         body: %Valimc.Entity.NativeBody{} = row
       }) do
    {width, height, _} = row.dimensions
    gravity = if row.no_gravity, do: 0.0, else: row.gravity

    {{x * 1.0, y * 1.0, z * 1.0}, {width / 2, height}, row.velocity,
     {row.on_ground, row.step_height * 1.0, true, false}, {0.0, false, true, gravity * 1.0, 0.98}}
  end

  defp push_body(%{kind: :object, entity: %{x: x, y: y, z: z}, body: %Body{} = body}) do
    case Valimc.Data.EntityTypes.fetch(body.type) do
      nil ->
        nil

      facts ->
        gravity = if body.no_gravity, do: 0.0, else: 0.04

        {{x * 1.0, y * 1.0, z * 1.0},
         {Valimc.Data.Float32.round(facts.width) / 2, Valimc.Data.Float32.round(facts.height)},
         body.velocity, {body.on_ground, 0.0, true, body.type == "minecraft:area_effect_cloud"},
         {0.0, false, false, gravity, 0.98}}
    end
  end

  defp push_body(_), do: nil

  # The rules' level settings: the dimension's fluid attributes, the source
  # conversion game rules and whether TNT explodes (VMC-047a).
  defp fluid_options(state) do
    Valimc.Blocks.Fluids.options(
      Valimc.World.Dimension.facts(state.dimension).type,
      Valimc.World.GameRules.get(:water_source_conversion),
      Valimc.World.GameRules.get(:lava_source_conversion)
    ) ||| if(Valimc.World.GameRules.get(:tnt_explodes), do: 16, else: 0)
  end

  # A run's sounds and the block events it ran (VMC-047a, VMC-048b), to the
  # players near them; a sound the acting player already played (its
  # client's) skips that player's connection. A note block's event plays its
  # instrument, a piston's moves the blocks on the clients within 64 blocks
  # (`runBlockEvents`' broadcast), whose own pistons move them.
  defp play_redstone(state, %{sounds: [], executed: []}, _input), do: state

  defp play_redstone(state, outcome, input) do
    actor = Map.get(input, :actor)

    for {{x, _, z} = at, index, volume, pitch, by_actor} <- outcome.sounds do
      packet = Redstone.sound_packet(Redstone.sound(index), "block", at, volume, pitch)

      key = Grid.section(state.dimension, Grid.chunk_key(floor(x), floor(z)))
      except = if by_actor, do: actor
      Valimc.World.publish(key, {:sound, at, max(volume, 1.0) * 16.0, packet, except})
    end

    changes = Map.new(outcome.changes)

    for {{x, y, z} = position, block, b0, b1} <- outcome.executed do
      at = {x + 0.5, y + 0.5, z + 0.5}
      key = Grid.section(state.dimension, Grid.chunk_key(x, z))
      event = Valimc.Protocol.Packets.block_event(position, b0, b1, block)
      Valimc.World.publish(key, {:sound, at, 64.0, event, nil})

      # A note block's sound is the instrument its state names at the event.
      current = Map.get(changes, position) || read_block(state, position)

      for {sound, pitch} <- List.wrap(current && Redstone.note_sound(current)),
          do:
            Valimc.World.publish(
              key,
              {:sound, at, 48.0, Redstone.sound_packet(sound, "record", at, 3.0, pitch), nil}
            )
    end

    state
  end

  # What the block rules read beyond this section: the stores of the group's
  # sections beside it (at least 128 blocks of reach on every side, beyond any
  # one run's cascade), and their chunks not generated yet. Passing the whole
  # group made every run lock and list every section of a wide view.
  defp rule_reach(state) do
    near = for {_, sibling} <- neighbours(state), do: sibling
    own = MapSet.to_list(state.generation.absent)
    absent = Enum.reduce(near, own, fn sibling, acc -> sibling.absent ++ acc end)
    {for(sibling <- near, do: sibling.blocks), absent}
  end

  # The group's other sections beside this one (`{key, peer}`), by key
  # rather than by walking every section of the group.
  defp neighbours(%{key: {sx, sz}, siblings: siblings}) do
    for dx <- -1..1,
        dz <- -1..1,
        {dx, dz} != {0, 0},
        key = {sx + dx, sz + dz},
        {:ok, peer} <- [Map.fetch(siblings, key)],
        do: {key, peer}
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
      dispensed: [],
      outputs: [],
      pistons: [],
      hidden: []
    }

    [
      changes: outcome.changes,
      destroyed: outcome.destroyed,
      ticks: outcome.ticks,
      fluid_ticks: outcome.fluid_ticks,
      events: outcome.events,
      primed: for(cell <- outcome.primed, do: {cell}),
      dispensed: for(cell <- outcome.dispensed, do: {cell}),
      outputs: outcome.outputs,
      pistons: outcome.pistons,
      hidden: for(cell <- outcome.hidden, do: {cell})
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
  def apply_sibling(state, {:entity_change, id, revision, change}) do
    # Prepared from this group's authoritative store with no owner boundary.
    {:ok, store} = Store.change_entry(state.entities.store, id, revision, change)
    # Its death drops are already resolved in the following entity records.
    {store, _deaths} = Store.take_deaths(store)
    put_entities(state, store)
  end

  def apply_sibling(state, {:mob_drops, drops}), do: mob_drops(state, drops)
  def apply_sibling(state, {:free_knots, positions}), do: free_knots(state, positions)
  def apply_sibling(state, {:make_knots, positions}), do: make_knots(state, positions)
  def apply_sibling(state, {:rules, part}), do: apply_rules(state, part)
  def apply_sibling(state, {:piston_pushes, pushes}), do: push_own(state, pushes)
  def apply_sibling(state, {:shulker_push, push}), do: displace_own(state, push)
  def apply_sibling(state, {:halo, message}), do: Valimc.World.LightHalo.handle(message, state)

  def apply_sibling(state, {:entities, source, records}) do
    {store, refused} =
      Enum.reduce(records, {state.entities.store, []}, fn record, {store, refused} ->
        with false <- Store.reserved_uuid?(store, record.uuid),
             {:ok, next, {_, id, _}} <- Store.create_record(store, state.key, record) do
          {live_body(next, id, record), refused}
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

  def apply_sibling(state, {:dragon_killed, uuid}),
    do: Valimc.World.Dragon.Arena.complete(state, uuid, arena_ops())

  def apply_sibling(state, {:arena_entries, entries}) do
    {:ok, entities} = BlockEntities.add(state.block_entities, entries)
    %{state | block_entities: entities}
  end

  def apply_sibling(%{arena: arena} = state, {:arena_crystal_destroyed, count, uuid})
      when arena != nil,
      do:
        Valimc.World.Dragon.Ritual.destroyed(
          %{state | arena: %{arena | alive_crystals: count, scan: 0}},
          uuid,
          arena_ops()
        )

  def apply_sibling(state, :arena_try_respawn),
    do: Valimc.World.Dragon.Ritual.try_respawn(state, arena_ops())

  def apply_sibling(state, {:arena_effect, effect}),
    do: Valimc.World.Dragon.Arena.effect(effect, state, arena_ops())

  # A sibling's hoppers' inserts into this section's containers (VMC-049a).
  def apply_sibling(state, {:hopper_inserts, inserts}), do: hopper_inserts(state, inserts)

  def apply_sibling(state, {:container_entries, expected, next, content}) do
    true = state.containers == expected
    containers_moved(%{state | containers: next}, content)
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

    knot =
      with {:ok, {_, id, _}} <- Store.find(store, uuid),
           %{body: %Body{type: @knot}, entity: e} <- store.entries[id],
           do: {id, e}

    case knot do
      # A fence knot breaks (VMC-043c3, `BlockAttachedEntity.hurtServer`): its
      # mobs let go on their next tick.
      {id, e} when is_integer(id) ->
        pos = {floor(e.x), floor(e.y), floor(e.z)}
        state = state |> remove_entry(id) |> knot_sound(pos, "minecraft:item.lead.untied")
        {{:ok, %{hurt: true}}, state}

      _ ->
        hurt_body(state, uuid, hit)
    end
  end

  defp hurt_body(state, uuid, hit) do
    store = state.entities.store

    with {:ok, {_, id, _}} <- Store.find(store, uuid),
         entry = store.entries[id],
         {:ok, store, outcome} <- Valimc.Entity.Combat.hurt(store, id, hit) do
      state = state |> put_entities(store) |> combat_feedback(entry, outcome)

      state =
        case outcome do
          %{crystal: point} = outcome ->
            state = if outcome.explode, do: explode(state, Explosion.crystal(point)), else: state
            crystal_destroyed(state, entry.entity, hit)

          _ ->
            state
        end

      {{:ok, Map.drop(outcome, [:crystal, :explode, :feedback])}, state}
    else
      {:error, _} = error -> {error, state}
    end
  end

  # A removed body cannot retain tracker events. Publish its bounded terminal
  # feedback once, after the authoritative store admitted the hit.
  defp combat_feedback(state, entry, outcome),
    do: Enum.reduce(Map.get(outcome, :feedback, []), state, &projectile_effect(&2, entry, &1))

  defp terminal_event(state, entry, event, at, range) do
    packet = Body.event_packet(entry.entity.entity_id, event, entry.entity)
    Valimc.World.publish(route_key(state), {:sound, at, range, packet})
    state
  end

  @doc """
  Mob `uuid`'s melee attack on player `target` (`Mob.doHurtTarget`,
  VMC-037n), for VMC-041a's melee goal: the hit goes to the player's session
  in this group, which runs its hurt (`Player.Hurt`). `:ok` or `{:error,
  reason}`.
  """
  def mob_attack(state, uuid, target, extras \\ %{}) do
    store = state.entities.store

    with {:ok, {_, id, _}} <- Store.find(store, uuid),
         {:ok, hit} <- Valimc.Entity.Combat.mob_hit(store, id, "minecraft:player") do
      send(self(), {:player, target, {:hurt, Map.merge(hit, extras)}})
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
  def mob_shoot(state, uuid, {tx, ty, tz, height}, power \\ 1.0, opts \\ %{}) do
    store = state.entities.store

    with {:ok, {_, id, _}} <- Store.find(store, uuid),
         %{kind: :mob, body: %{type: type} = body, entity: e} <- store.entries[id],
         true <- Body.alive?(body) do
      difficulty = elem(Clock.difficulty(), 0).level
      eye = Valimc.Data.EntityTypes.fetch(type).eye_height

      # Where it shot from (VMC-043b: its goal's tick, before it moved).
      {x, y, z} =
        case opts do
          %{from: {fx, fy, fz}} ->
            {fx, fy - 0.10000000149011612, fz}

          _ ->
            {e.x * 1.0, Valimc.Data.Float32.round(e.y + eye) - 0.10000000149011612, e.z * 1.0}
        end

      owner = %{uuid: e.uuid, id: e.entity_id, player: false, type: type}
      arrow = Projectile.new("minecraft:arrow", owner, Valimc.Protocol.ItemStack.new("arrow"))

      # A stray's or bogged's arrow carries its effect (`getArrow`).
      arrow =
        case opts[:effect] do
          nil -> arrow
          effect -> %{arrow | data: %{arrow.data | effects: [effect]}}
        end

      # `setBaseDamageFromMob`: `power * 2 + triangle(difficulty * 0.11, 0.57425)`.
      damage =
        Valimc.Data.Float32.round(power * 2.0) + difficulty * 0.11 +
          0.57425 * (:rand.uniform() - :rand.uniform())

      arrow =
        %{arrow | data: %{arrow.data | damage: damage}}
        |> Projectile.arm(opts[:weapon], Valimc.Protocol.ItemStack.new("arrow"))

      {xd, zd} = {tx - x, tz - z}
      distance = :math.sqrt(xd * xd + zd * zd)
      yd = ty + height / 3.0 - y + distance * Valimc.Data.Float32.round(0.2)
      arrow = Projectile.shoot(arrow, {xd, yd, zd}, 1.6, 14 - difficulty * 4)
      record = Store.body_record(arrow, :crypto.strong_rand_bytes(16), {x, y, z})

      case Store.create_record(store, state.key, record) do
        {:ok, store, _} ->
          # The pitch its own random drew (VMC-043b), else the owner's.
          pitch =
            opts[:pitch] ||
              Valimc.Data.Float32.round(
                1.0 / Valimc.Data.Float32.round(:rand.uniform() * 0.4 + 0.8)
              )

          state = put_entities(state, store)
          {sx, _, sz} = {x, y, z}
          sy = if opts[:from], do: elem(opts.from, 1) - eye, else: e.y

          {:ok,
           projectile_effect(
             state,
             nil,
             {:sound, "minecraft:entity.skeleton.shoot", "hostile", {sx, sy, sz}, 1.0, pitch}
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
  defp drop_death(store, key, death) do
    Enum.reduce(death_records(death), store, fn record, acc ->
      case Store.create_record(acc, key, record) do
        {:ok, next, _} -> next
        {:error, _} -> acc
      end
    end)
  end

  defp death_records({death, {x, y, z} = position}) do
    drops = Valimc.World.GameRules.get(:mob_drops)
    death = Map.put(death, :position, position)

    stacks =
      with true <- drops and death.loot_table != nil and not death.loot.baby,
           <<seed::signed-64>> = :crypto.strong_rand_bytes(8),
           # The killing player's luck (`withLuck`).
           {:ok, stacks} <-
             Valimc.Blocks.Loot.entity_drops(death.loot_table, seed, death.position, death.loot,
               luck: Map.get(death, :luck, 0.0)
             ) do
        stacks
      else
        _ -> []
      end

    # Its equipment as it fell (`dropCustomDeathLoot`, VMC-043b).
    stacks = if drops, do: stacks ++ Map.get(death, :equipment, []), else: stacks

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

    items ++ orbs
  end

  defp put_entities(state, store) when store == state.entities.store, do: state

  # Every hurt path's deaths drop here, as `LivingEntity.die` drops them.
  defp put_entities(state, store) do
    state = %{state | entities: %{state.entities | store: store}}
    if store.deaths == [], do: publish_item_views(state), else: drop_deaths(state)
  end

  # The deaths of the mobs' own ticks and timers (burning, drowning, a
  # fall) drop at the end of the entity phase.
  defp drop_deaths(%{entities: %{store: %{deaths: []}}} = state), do: state

  defp drop_deaths(state) do
    {store, deaths} = Store.take_deaths(state.entities.store)
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

      # Native mobs (VMC-081d) leave their section whole.
      parcels =
        Store.native_parcels(
          moved,
          for(
            record <- records,
            Store.native_entry?(moved.entries[moved.uuids[record.uuid]]),
            do: moved.uuids[record.uuid]
          )
        )

      # Within one owner, carry the live body as the existing spawn/adopt
      # path does. Saving/reloading a record here would reset AI and combat
      # windows, and discard this tick's simulation fences.
      records =
        Enum.map(records, fn record ->
          id = moved.uuids[record.uuid]

          entry = moved.entries[id]

          record =
            Map.put(
              record,
              :entity_counters,
              Map.take(entry, [:idle, :lived, :aged_tick, :simulated_tick, :knot_checks])
            )

          case entry do
            %{body: %Body{} = body} -> Map.put(record, :spawn_body, body)
            %{native: ref} when ref != nil -> Map.put(record, :native_parcel, parcels[id])
            _ -> record
          end
        end)

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

    hidden = for {cell} <- Map.get(part, :hidden, []), into: MapSet.new(), do: cell

    state
    |> schedule_ticks(rule_ticks(state, changes, ticks) ++ fluid_ticks)
    |> put_pistons(Map.get(part, :pistons, []))
    |> commit_rule_changes(changes, drops, breaks, hidden)
    |> rule_events(part.events)
    |> prime_tnt(for({cell} <- Map.get(part, :primed, []), do: cell))
    |> put_outputs(Map.get(part, :outputs, []))
    |> dispense(for({cell} <- Map.get(part, :dispensed, []), do: cell))
  end

  # Moving pistons' block entities the rules changed (VMC-048b): nil for one
  # gone. The store keeps them beside the cells, its snapshots publish them
  # (their shapes), and the chunks' packets list them.
  defp put_pistons(state, []), do: state

  defp put_pistons(state, pistons) do
    kept =
      Enum.reduce(pistons, state.pistons, fn
        {position, nil}, acc -> Map.delete(acc, position)
        {position, moving}, acc -> Map.put(acc, position, moving)
      end)

    chunks = Blocks.put_pistons(state.blocks, Map.new(pistons))

    %{state | pistons: kept, piston_order: next_piston_order(pistons, state.piston_order)}
    |> light_changed(chunks)
    |> publish_block_snapshots(chunks)
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

  defp commit_rule_changes(state, edits, _drops, _breaks, _hidden) when map_size(edits) == 0,
    do: state

  defp commit_rule_changes(state, edits, [], _breaks, hidden) do
    with {:ok, batch} <- BlockBatch.prepare(edits),
         {:ok, proposal} <- block_proposal(state, batch) do
      publish_blocks(state, client_frames(batch, edits, hidden), proposal, false, false)
    else
      _ -> state
    end
  end

  # Destroyed blocks break like vanilla `destroyBlock` (or, with no particles
  # and sound, `removeBlock` after `dropResources`): they leave their fluid and
  # drop their tool-less loot, in the frame that writes the rules' changes.
  defp commit_rule_changes(state, edits, drops, breaks, hidden) do
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
      batch = client_frames(batch, edits, hidden)
      {state, effects} = apply_blocks(state, batch, proposal, false, false)
      state = publish_item_views(%{state | entities: %{state.entities | store: items}})

      state
      |> release_blocks(effects)
      |> release_effect({:level_events, for({p, b} <- breaks, do: {p, 2001, b})})
    else
      _ -> state
    end
  end

  # Bone meal on a tall flower or a full flower bed drops a copy
  # (`Block.popResource(level, pos, new ItemStack(this))`, VMC-039b).
  defp pop_block_item(state, position, block) do
    name = Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(block))
    stack = Valimc.Protocol.ItemStack.new(name)
    pop_items(state, [stack], &Valimc.Entity.ItemDrop.pop(position, &1))
  end

  # A transformer entry's loot (VMC-039b: a hoe tilling rooted dirt drops its
  # hanging roots), rolled for the block it transformed and popped by the
  # entry's drop strategy.
  defp transform_loot(state, {:transform, position, tool, face}, index, block) do
    entry = Valimc.Blocks.Transformers.entry(tool, index - 1)

    with table when is_binary(table) <- entry.loot,
         {:ok, stacks} <-
           Valimc.Blocks.Loot.block_drops(table, :rand.uniform(1 <<< 62), position, %{
             state: block,
             entity: true
           }) do
      pop =
        if entry.drop == "clicked_face",
          do: &Valimc.Entity.ItemDrop.pop_from_face(position, face, &1),
          else: &Valimc.Entity.ItemDrop.pop(position, &1)

      pop_items(state, stacks, pop)
    else
      _ -> state
    end
  end

  # Stacks popped, each record made by `pop`.
  defp pop_items(state, [], _pop), do: state

  defp pop_items(state, stacks, pop) do
    items =
      Enum.reduce(stacks, state.entities.store, fn stack, acc ->
        case Store.create_record(acc, state.key, pop.(stack)) do
          {:ok, next, _} -> next
          {:error, _} -> acc
        end
      end)

    publish_item_views(%{state | entities: %{state.entities | store: items}})
  end

  # What clients hear of a commit: no write of a moving piston's cells told
  # them (VMC-048b, `UPDATE_CLIENTS` off), which their own piston makes from
  # the block event, so those cells stay out of its frames.
  defp client_frames(batch, edits, hidden) do
    if MapSet.size(hidden) == 0 do
      batch
    else
      case BlockBatch.prepare(Map.drop(edits, MapSet.to_list(hidden))) do
        {:ok, visible} -> %{batch | frames: visible.frames}
        {:error, _} -> %{batch | frames: []}
      end
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

    # Mobs a block made (VMC-043e: a turtle egg's hatchlings), not finalized
    # (`EntityType.create`), with the data it gave them.
    records =
      records ++
        for {:mob, type, at, opts} <- effects,
            {:ok, body} <- [Body.new(type)] do
          body = %{body | data: Map.merge(body.data, Map.get(opts, :data, %{}))}
          Store.body_record(body, :crypto.strong_rand_bytes(16), at)
        end

    # Their sounds (`playSound(null, pos, ...)`) and level events.
    for {:sound, position, name, volume, pitch} <- effects,
        do: Valimc.World.Sounds.play(position, name, :block, volume, pitch)

    level_events = for {:level_event, position, type, data} <- effects, do: {position, type, data}
    if level_events != [], do: publish_level_events(state, level_events)

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

    {tracking, publication} =
      Tracking.pass(
        state.entities.tracking,
        store.views,
        {state.player_views, %{}},
        store.ledger.outgoing,
        state.entities.tracking.tick
      )

    :ok = Publication.publish(state.publication, state.epoch, tracking.tick, publication)
    %{state | entities: %{state.entities | tracking: tracking}}
  end

  # The entities phase's end (VMC-077h, VMC-081i): the trackers of entities
  # in simulated chunks or whose view changed tick once (a native mob's in
  # its section), and the frame of their changes is published with the rows
  # that changed. A section whose store and players did not change and that
  # simulates nothing costs one comparison (VMC-077w: most of a flying
  # player's view).
  defp track_entities(state) do
    store = state.entities.store

    simulated =
      if Tickets.simulating?(state.tickets), do: state.tickets.simulated, else: MapSet.new()

    tracking = state.entities.tracking
    players = {state.player_views, state.player_frame}

    if Tracking.idle?(tracking, store.views, players, simulated) do
      # Equal views may be another term (a state copied in by message):
      # the pass keeps these, so the next check compares by identity
      # (VMC-081j).
      case Tracking.same(tracking, store.views, state.player_views) do
        :same -> state
        {:rebased, tracking} -> %{state | entities: %{state.entities | tracking: tracking}}
      end
    else
      native = store.native

      mask =
        if native != nil and MapSet.size(simulated) > 0,
          do: Valimc.Entity.NativeMobs.simulated_mask(state.key, simulated),
          else: 0

      {tracking, publication} =
        Tracking.pass(
          tracking,
          store.views,
          players,
          store.ledger.outgoing,
          state.game_tick,
          simulated: simulated,
          native: native,
          mask: mask
        )

      :ok = Publication.publish(state.publication, state.epoch, tracking.tick, publication)
      %{state | entities: %{state.entities | tracking: tracking}, player_frame: %{}}
    end
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

  # A transient live body crosses only an in-process adoption. Durable
  # records and the cross-owner handoff ledger keep their existing codecs.
  defp live_body(store, id, record),
    do:
      Store.restore_live(
        store,
        id,
        Map.get(record, :spawn_body),
        Map.get(record, :entity_counters, %{})
      )

  defp adopt_drops(state, records) do
    items =
      Enum.reduce(records, state.entities.store, fn record, items ->
        case Store.create_record(items, state.key, record) do
          {:ok, next, {_, id, _}} ->
            live_body(next, id, record)

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
  Finish aquatic packs across the group's sections before any member is
  published (`Native.mob_finalize/2`): each member's `finalizeSpawn`
  with its pack's shared data, in spawn order, on its section's level
  random; a schooling fish keeps the school its pack made (`school`).
  """
  def spawn_packs(sections, plan) do
    entries =
      for {key, {records, _, _, _}} <- plan,
          Map.has_key?(sections, key),
          record <- records,
          Map.has_key?(record, :spawn_pack),
          do: {key, record}

    if entries == [] do
      {sections, plan}
    else
      entries = Enum.sort_by(entries, fn {_, record} -> record.spawn_order end)
      keys = entries |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      slots = Map.new(Enum.with_index(keys))
      packs = entries |> Enum.map(&elem(&1, 1).spawn_pack) |> Enum.uniq()
      packs = Map.new(Enum.with_index(packs))

      randoms =
        for key <- keys,
            do: Map.fetch!(sections, key).ai_random || Valimc.Data.JavaRandom.create()

      private = [:spawn_pack, :spawn_order, :spawn_school]

      {:ok, {finished, randoms}} =
        Native.mob_finalize(
          for {key, record} <- entries do
            {slots[key], packs[record.spawn_pack], record.spawn_school, Map.drop(record, private)}
          end,
          randoms
        )

      sections =
        Enum.reduce(Enum.zip(keys, randoms), sections, fn {key, random}, acc ->
          Map.update!(acc, key, &%{&1 | ai_random: random})
        end)

      finished =
        Map.new(finished, fn {record, school} ->
          {record.uuid, if(school, do: Map.put(record, :school, school), else: record)}
        end)

      plan =
        Map.new(plan, fn {key, {records, discards, resets, events}} ->
          records =
            Enum.map(records, fn record ->
              Map.get(finished, record[:uuid], record)
            end)

          {key, {records, discards, resets, events}}
        end)

      {sections, plan}
    end
  end

  @doc """
  A tick's natural spawning in this section (VMC-042a, `World.Spawning`):
  it adopts the records of the mobs that spawned (queued like drops while a
  plan runs), discards the mobs that despawn, unless a plan or a write is
  under way (they are checked again next tick), and restarts the idle time
  of those a player came near.
  """
  def spawned(state, records, discards, resets) do
    {sections, plan} = spawn_packs(%{state.key => state}, %{state.key => {records, [], [], []}})
    state = sections[state.key]
    {records, _, _, _} = plan[state.key]

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
           data: pending |> Map.put(:from, from) |> Map.put(:base_store, state.entities.store)
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

  # `opts`: `:drop`, how a removed shulker box drops (`ContainerSpills.add/4`),
  # and `:fill`, the slots a placed shulker box starts with by position.
  defp start_container_blocks(state, from, batch, expected, reply, opts) do
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
           {:ok, change} <- fill_placed(change, key, batch, Keyword.get(opts, :fill, %{})),
           {:ok, next} <-
             ContainerSpills.add(items, key, change.removed, Keyword.get(opts, :drop, :loot)),
           do: {:ok, Map.put(change, :items, next)}

    job_done(:plan, Map.put(pending, :from, from), result, state)
  end

  # A shulker box placed from an item holding contents starts with them
  # (`BaseContainerBlockEntity.applyImplicitComponents`), in the commit that
  # creates its entry.
  defp fill_placed(change, _key, _batch, fill) when map_size(fill) == 0, do: {:ok, change}

  defp fill_placed(change, key, batch, fill) do
    Enum.reduce_while(fill, {:ok, change}, fn {position, slots}, {:ok, acc} ->
      with true <- Valimc.Blocks.ShulkerBox.shulker_box?(batch.edits[position]),
           %{kind: :shulker_box, revision: revision} <- acc.containers.entries[position],
           {:ok, containers, _} <- Containers.replace(acc.containers, position, revision, slots),
           {:ok, _} <- Containers.encode(key, containers) do
        {:cont, {:ok, %{acc | containers: containers}}}
      else
        _ -> {:halt, {:error, :invalid_container_contents}}
      end
    end)
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
          not MapSet.member?(entities, position) and
            BlockEntities.live(state.block_entities, position, block) == nil
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

  @doc "Prepare one half of an authorized chest menu inside the owning group."
  def prepare_chest(state, position, unpack) do
    state = if unpack, do: unpack_loot(state, position, 0.0), else: state
    ensure_container(state, position)
  end

  # Vanilla unpacks when a player who may open the chest or barrel opens it:
  # not a spectator, and only where the open itself succeeds (`createMenu`),
  # with the opener's luck (`unpackLootTable(player)`: Luck and Bad Luck).
  defp unpack_to_open(state, {x, y, z} = position, %{kind: :open, mode: mode} = grant)
       when mode != :spectator do
    block = Blocks.get(state.blocks, position)

    if write_busy(state) == nil and
         LootChests.unrolled?(state.containers, state.block_entities, position, block) do
      menu = Valimc.Menus.MenuAccess.menu(block)

      provisional =
        if menu == :storage,
          do: %{kind: Valimc.Blocks.Storage.kind(block), slots: {}, revision: 0},
          else: %{rows: 3, slots: Tuple.duplicate(nil, 27), revision: 0}

      above = Blocks.get(state.blocks, {x, y + 1, z})
      now = System.monotonic_time(:millisecond)

      above = if menu == :storage, do: shulker_room(state, position, block), else: above

      case Valimc.Menus.MenuAccess.authorize(
             menu,
             block,
             provisional,
             above,
             position,
             grant,
             now
           ) do
        {^menu, _, _} -> unpack_loot(state, position, Map.get(grant, :luck, 0.0))
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
         # Names, locks and other unowned data stay preserved, in either half.
         nil <- BlockEntities.live(state.block_entities, position, block),
         {:ok, containers} <-
           ContainerLifecycle.ensure(state.containers, state.key, position, block) do
      %{state | containers: containers}
    else
      _ -> state
    end
  end

  # A container block set without a container plan (a command, a raw set)
  # gets its empty entry, as vanilla's block entity comes with the block
  # (VMC-049a: a hopper reaches it at once); a preserved one stays preserved.
  defp ensure_containers(containers, state, changes) do
    Enum.reduce(changes, containers, fn {position, block}, acc ->
      with true <- Valimc.Blocks.block_entity(block) != nil,
           nil <- BlockEntities.live(state.block_entities, position, block),
           {:ok, next} <- ContainerLifecycle.ensure(acc, state.key, position, block) do
        next
      else
        _ -> acc
      end
    end)
  end

  # `ShulkerBoxBlock.canOpen`: a box nobody holds open (its lid closed)
  # opens only when the half block in front of its lid is clear; `:blocked`
  # otherwise. A front cell in another section is read from its published
  # blocks. ValiMC does not run the lid's ten closing ticks, so a box counts
  # as closed as soon as its last viewer leaves.
  defp shulker_room(state, position, block) do
    if Valimc.Blocks.ShulkerBox.shulker_box?(block) and
         ContainerViewers.open_count(state.container_viewers, position) == 0 do
      {_, y, _} = front = Valimc.Blocks.ShulkerBox.front(block, position)

      neighbour =
        cond do
          not Chunk.valid_y?(y) ->
            nil

          in_region?(state, front) ->
            Blocks.get(state.blocks, front)

          true ->
            state.dimension
            |> Valimc.World.View.new()
            |> Valimc.World.View.blocks([front])
            |> hd()
        end

      if Valimc.Blocks.ShulkerBox.lid_clear?(block, position, neighbour),
        do: :clear,
        else: :blocked
    else
      :clear
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
  # lecterns, locked chests...); ValiMC cannot perform it, so it refuses rather
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
    preserved =
      case BlockEntities.in_chunk(state.block_entities, chunk) do
        [] ->
          []

        positions ->
          BlockEntities.chunk_entries(
            state.block_entities,
            chunk,
            positions,
            Blocks.get_many(state.blocks, positions)
          )
      end

    # Moving pistons' block entities (VMC-048b), with their update tags.
    preserved ++
      for {{x, _, z} = position, moving} <- state.pistons,
          Grid.chunk_key(x, z) == chunk,
          do:
            {position, Valimc.Blocks.MovingPistons.type_id(),
             Valimc.Blocks.MovingPistons.update_tag(moving)}
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

        # A chest's or a machine's state that keeps its container (a hopper's
        # `enabled`, a dispenser's `triggered`) keeps its entry; one that
        # ends it with contents must spill them in the same commit.
        %{slots: slots} = entry ->
          original = Blocks.get(state.blocks, position)

          block != original and Enum.any?(Tuple.to_list(slots), &(&1 != nil)) and
            Valimc.Blocks.block_entity(block) != Valimc.Blocks.block_entity(original) and
            retired[position] != entry

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
      | containers:
          state.containers
          |> ContainerLifecycle.retire_replaced(proposal.changes)
          |> ensure_containers(state, proposal.changes)
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

  # A chunk's packet is encoded as job `{:encode, chunk}`; `encodes` holds the
  # callers waiting for it.
  defp start_encode(state, key) do
    if Jobs.running?(state.jobs, {:encode, key}) do
      state
    else
      # Section encoding is a short NIF call on the owner; packet assembly and
      # compression run in the worker from these immutable binaries.
      started = System.monotonic_time(:microsecond)

      # A generated chunk's first packet: its job encoded it (VMC-081c2).
      {encoded, entities} =
        case Blocks.prepared(state.blocks, key) do
          nil ->
            encoded = Blocks.encode(state.blocks, key)

            {encoded,
             if(encoded == :flat, do: %{}, else: Blocks.chunk_entities(state.blocks, key))}

          prepared ->
            prepared
        end

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

  def handle_info(:light_retry, state),
    do: {:noreply, Valimc.World.LightUpdates.start(%{state | light_retry: false})}

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

  # A player's effects as its body goes (VMC-037p): `removal_effects/4`.
  def handle_info({:effect_removal, at, height, actions}, state),
    do: {:noreply, removal_effects(state, at, height, actions)}

  # Infested's silverfish from a hurt player (VMC-037p).
  def handle_info({:infested, at, velocities}, state) do
    spawns =
      for v <- velocities,
          do: {nil, {:spawn_mob, "minecraft:silverfish", at, %{velocity: v, hurt_sound: true}}}

    {:noreply, Enum.reduce(spawns, state, &mob_spawns/2)}
  end

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
  defp redstone_use(state, epoch, viewer, position, grant) do
    with true <- use_granted?(state, epoch, position, grant),
         true <- Redstone.usable?(Blocks.get(state.blocks, position)) do
      facing = Enum.at([3, 4, 2, 5], Bitwise.band(floor((grant[:yaw] || 0.0) / 90.0 + 0.5), 3))
      action = {:use, position, facing, grant.mode != :adventure}

      case rule_run(state, %{actions: [action], actor: viewer}) do
        {state, %{results: [1]}} -> {:used, state}
        _ -> :pass
      end
    else
      _ -> :pass
    end
  end

  # Berries picked (VMC-039b, `Valimc.Blocks.Harvest`): the loot of the
  # berried state, then the rules pick them, then the sound for everyone.
  defp harvest_use(state, epoch, viewer, position, grant) do
    with true <- use_granted?(state, epoch, position, grant),
         block = Blocks.get(state.blocks, position),
         {:ok, harvest} <- Valimc.Blocks.Harvest.of(block, grant[:main_item]),
         {:ok, stacks} <-
           Valimc.Blocks.Loot.block_drops(harvest.table, :rand.uniform(1 <<< 62), position, %{
             state: block,
             entity: true
           }),
         {state, %{results: [1]}} <-
           rule_run(state, %{actions: [{:harvest, position}], actor: viewer}) do
      {x, y, z} = position
      at = {x + 0.5, y + 0.5, z + 0.5}
      seed = :rand.uniform(1 <<< 62)
      sound = Valimc.World.Sounds.packet(harvest.sound, :block, at, seed, harvest.pitch)
      Valimc.World.publish(route_key(state), {:sound, at, 16.0, sound})
      {:used, pop_items(state, stacks, &Valimc.Entity.ItemDrop.pop(position, &1))}
    else
      _ -> :pass
    end
  end

  # Shears on a full beehive or a pumpkin (VMC-039c, `Valimc.Blocks.Shearing`):
  # the block's interaction loot, then the rules empty or carve it, then its
  # sound for everyone (a hive's at the player); the player wears the shears.
  defp shear_use(state, epoch, viewer, position, grant) do
    with true <- use_granted?(state, epoch, position, grant),
         block = Blocks.get(state.blocks, position),
         {:ok, shear} <-
           Valimc.Blocks.Shearing.of(block, grant[:item], grant[:face], grant[:yaw]),
         {:ok, stacks} <-
           Valimc.Blocks.Loot.block_drops(shear.table, :rand.uniform(1 <<< 62), position, %{
             state: block,
             entity: true
           }),
         {state, %{results: [1]}} <-
           rule_run(state, %{actions: [{:shear, position, shear.facing}], actor: viewer}),
         true <- Blocks.get(state.blocks, position) != block do
      {x, y, z} = position
      at = if shear.carved, do: {x + 0.5, y + 0.5, z + 0.5}, else: grant[:feet] || {x, y, z}
      sound = Valimc.World.Sounds.packet(shear.sound, :block, at, :rand.uniform(1 <<< 62))
      Valimc.World.publish(route_key(state), {:sound, at, 16.0, sound})

      pop =
        if shear.carved,
          do: &Valimc.Entity.ItemDrop.carved(position, shear.facing, &1),
          else: &Valimc.Entity.ItemDrop.pop(position, &1)

      {:sheared, pop_items(state, stacks, pop)}
    else
      _ -> :pass
    end
  end

  # A player's use of a block reaches its owner in time, within reach, with
  # the main hand and not suppressed by sneaking with an item (`useItemOn`).
  defp use_granted?(state, epoch, position, %{kind: :open} = grant) do
    now = System.monotonic_time(:millisecond)

    with true <- epoch == state.epoch and valid_block_query?([position], :any),
         true <- in_region?(state, position),
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
      true
    else
      _ -> false
    end
  end

  defp use_granted?(_state, _epoch, _position, _grant), do: false

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

            Valimc.Blocks.Chest.ordinary?(block) or (is_map(grant) and grant[:menu] == :chest) ->
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

            # Hoppers, droppers and dispensers (VMC-049a), barrels (VMC-032c1)
            # and shulker boxes (VMC-032c2).
            Valimc.Menus.MenuAccess.menu(block) in [:hopper, :dispenser, :storage] or
                (is_map(grant) and grant[:menu] in [:hopper, :dispenser, :storage]) ->
              Valimc.Menus.MenuAccess.authorize(
                Valimc.Menus.MenuAccess.menu(block) || grant[:menu],
                block,
                state.containers.entries[position],
                shulker_room(state, position, block),
                position,
                grant,
                now
              )

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

  @menu_containers Valimc.Menus.MenuAccess.containers()

  defp container_view_decision(state, connection, position, grant, decision) do
    generation = Map.get(state.cooking_progress, position, 0)

    decision =
      case decision do
        {:cooking, block, entry} -> {:cooking, block, Map.put(entry, :generation, generation)}
        _ -> decision
      end

    if is_map(grant) and grant[:menu] in Valimc.Menus.MenuAccess.containers() and
         (decision == :valid or
            match?({kind, _, _} when kind in @menu_containers, decision)) do
      ref = grant[:view_ref]
      view = state.container_viewers.views[connection]
      opener = grant.menu in Valimc.Menus.MenuAccess.openers() and grant.mode != :spectator

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

  def notify_container_changed(state, position) do
    case state.containers.entries[position] do
      %{revision: revision} ->
        {viewers, notices} = ContainerViewers.changed(state.container_viewers, position, revision)

        for {pid, ref, revision} <- notices do
          view = viewers.views[pid]
          owner = view.origin || {self(), state.epoch}

          Valimc.Player.PlayerList.deliver(
            pid,
            {:container_changed, owner, ref, view.position, revision}
          )
        end

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
            {:container_closed, view.origin || {self(), state.epoch}, view.ref}
          )

    apply_container_viewers(state, {viewers, retired, lids}, false)
  end

  def apply_container_viewers(state, {viewers, retired, lids}, sound? \\ true) do
    for view <- retired, do: Process.demonitor(view.monitor, [:flush])
    state = %{state | container_viewers: viewers}
    threshold = Valimc.config(:compression_threshold)

    # A barrel shows its viewers by its `open` state, not by a lid event.
    {barrels, lids} =
      Enum.split_with(lids, fn {position, _} ->
        Valimc.Blocks.Barrel.barrel?(Blocks.get(state.blocks, position))
      end)

    for chunk <-
          lids
          |> Enum.map(fn {{x, _, z}, _} -> Grid.chunk_key(x, z) end)
          |> Enum.uniq() do
      positions =
        for {{x, _, z} = position, {_, count}} <- viewers.positions,
            count > 0 and Grid.chunk_key(x, z) == chunk,
            not Valimc.Blocks.Barrel.barrel?(Blocks.get(state.blocks, position)),
            do: position

      positions = Enum.sort(positions)

      if positions == [] do
        :ets.delete(state.publication, {:container_lids, chunk})
      else
        frame =
          positions
          |> Enum.map(&Packets.frame(lid_packet(state, &1, true), threshold))
          |> IO.iodata_to_binary()

        :ets.insert(
          state.publication,
          {{:container_lids, chunk}, state.epoch, positions, frame}
        )
      end
    end

    for {position, open} <- lids do
      frame = Packets.frame(lid_packet(state, position, open), threshold)
      block = Blocks.get(state.blocks, position)

      # A shulker box sounds at its own centre (`ShulkerBoxBlockEntity.startOpen`).
      {sound_position, kind} =
        if Valimc.Blocks.ShulkerBox.shulker_box?(block),
          do: {position, :shulker_box},
          else: {Valimc.Blocks.Chest.sound_position(block, position), :chest}

      sound =
        if sound? and sound_position != nil do
          <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
          draw = (:rand.uniform(16_777_216) - 1) / 16_777_216

          {:ok, packet} =
            Valimc.Protocol.ChestSounds.packet(open, sound_position, draw, seed, kind)

          Packets.frame(packet, threshold)
        end

      Valimc.World.publish(
        route_key(state),
        {:chest_lid, {self(), state.epoch}, position, open, frame, sound}
      )
    end

    # A removed barrel's viewers leave silently (`stopOpen` of a removed entity).
    if sound?, do: Enum.reduce(barrels, state, &barrel_opened/2), else: state
  end

  # A container's lid event: a chest's, or a shulker box's for its own block
  # (both block event 1, VMC-032c2).
  defp lid_packet(state, position, open) do
    block = Blocks.get(state.blocks, position)

    if Valimc.Blocks.ShulkerBox.shulker_box?(block),
      do: Valimc.Blocks.ShulkerBox.lid_event(block, position, open),
      else: Packets.chest_lid(position, open)
  end

  # The first viewer opens a barrel and the last one leaving closes it
  # (`BarrelBlockEntity`'s `onOpen`/`onClose`): its sound, and its `open`
  # state written as a furnace's `lit` is, keeping its entry, viewers and
  # grants. A refused write leaves the state for the next transition.
  defp barrel_opened({position, open}, state) do
    block = Blocks.get(state.blocks, position)
    next = Valimc.Blocks.Barrel.with_open(block, open)

    state =
      with true <- next != block,
           {:ok, batch} <- BlockBatch.prepare(%{position => next}),
           {:ok, proposal} <- block_proposal(state, batch) do
        {state, effects} = apply_blocks(state, batch, proposal, true)
        release_blocks(state, effects)
      else
        _ -> state
      end

    at = Valimc.Blocks.Barrel.sound_at(block, position)
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    draw = (:rand.uniform(16_777_216) - 1) / 16_777_216
    {:ok, packet} = Valimc.Protocol.ChestSounds.barrel_packet(open, at, draw, seed)
    Valimc.World.publish(route_key(state), {:sound, at, 16.0, packet})
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

  defp commit_simulated_items(state, steps, rest \\ false) do
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
            {:ok, items, handles} ->
              items = if rest, do: rest_unchanged(acc, items, batch, handles), else: items
              %{acc | entities: %{acc.entities | store: items}}

            {:error, _} ->
              acc
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
        entry = acc.entries[step.id]

        # A burned shulker box or bundle spills where it burned, or where it
        # was when its move left this section (VMC-004b8).
        with {:ok, next} <- Store.remove(acc, acc.epoch, step.id, step.revision),
             {:ok, next} <- spill_burned(next, state.key, entry, step.position) do
          next
        else
          _ -> acc
        end
      end)

    publish_item_views(%{state | entities: %{state.entities | store: store}})
  end

  defp spill_burned(store, key, %{kind: :item, stack: stack, entity: e}, {x, _, z} = position) do
    position =
      if Grid.region_key(Grid.chunk_key(x, z)) == key, do: position, else: {e.x, e.y, e.z}

    Valimc.Entity.ItemSpill.spill(store, key, stack, position)
  end

  defp spill_burned(store, _key, _entry, _position), do: {:ok, store}

  # Entities in portals (VMC-026c, VMC-026d): steps meeting a portal renew
  # their cooldown; one off cooldown starts this owner's single destination job.
  defp portal_contacts(state, local) do
    read = fn cells ->
      Blocks.get_many(state.blocks, Enum.filter(cells, &in_region?(state, &1)))
    end

    free = state.entities.portal == nil and not Jobs.running?(state.jobs, :portal)
    entries = state.entities.store.entries
    # A native mob's section renewed the cooldowns of those on cooldown and
    # names the touch of one off it (VMC-081d).
    {natives, others} = Enum.split_with(local, &Map.get(&1, :native, false))
    {others, travel} = EntityPortals.contacts(others, entries, read, free)

    native =
      if free,
        do:
          Enum.find_value(natives, fn step ->
            Enum.find_value(step.effects, fn
              {:portal, kind, cell} -> {step, entries[step.id], {kind, cell}}
              _ -> nil
            end)
          end)

    travel =
      case {travel, native} do
        {nil, native} -> native
        {travel, nil} -> travel
        {{a, _, _}, {b, _, _}} -> if b.id < a.id, do: native, else: travel
      end

    local = Enum.sort_by(others ++ natives, & &1.id)

    case travel do
      nil ->
        {local, state}

      {%{native: true} = step, entry, _} = travel ->
        case start_job(state, :portal, EntityPortals.work(travel),
               supervisor: Valimc.TransferWorkers,
               deadline: EntityPortals.deadline(),
               data: %{uuid: entry.entity.uuid}
             ) do
          {:ok, state} ->
            cooldown = EntityPortals.cooldown()

            state =
              case Native.mob_section_cooldown(entry.native, step.id, cooldown) do
                {:ok, {_, events, {position, row}}} ->
                  store =
                    Store.native_change(state.entities.store, step.id, position, row, events)

                  put_in(state.entities.store, store)

                _ ->
                  state
              end

            {local, state}

          {:error, _} ->
            {local, state}
        end

      {local_step, entry, _} = travel ->
        step = local_step

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

  # A plan's end (VMC-081d): the native mobs a handoff carried left with it
  # (`Store.sync_native/1`), or take back their state before the tick.
  defp native_plan_done(%{entities: %{store: %{native: nil}}} = state, _result), do: state

  defp native_plan_done(state, result) do
    if state.native_departing != [] do
      kept = if match?({:write, _, _}, result), do: state.native_departing, else: []
      :ok = Native.mob_section_settle(state.entities.store.native.ref, kept)
    end

    %{state | native_departing: []}
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

    # Every five seconds, the ticks of chunks that left simulation freeze.
    state =
      if rem(tick, 100) == 0,
        do: %{
          state
          | scheduled_ticks: ScheduledTicks.freeze(state.scheduled_ticks, state.tickets.simulated)
        },
        else: state

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
  defp job_done(:light_frames, job, frames, state),
    do: {:noreply, Valimc.World.LightUpdates.done(state, job, frames)}

  defp job_done(:dragon_pillars, _job, {:ok, plans}, state),
    do: {:noreply, %{state | arena_pillars: plans}}

  defp job_done(:dragon_pillars, _job, _error, state),
    do: {:noreply, %{state | arena_retry: state.game_tick + 20}}

  defp job_done(:cooking, job, {:ok, plan}, state),
    do: {:noreply, accept_cooking_plan(state, job, plan)}

  defp job_done(:cooking, _job, {:error, _}, state) do
    Valimc.Data.Metrics.add(:cooking_plan_failures)
    {:noreply, retry_cooking(state, 1000)}
  end

  # A crater job ended (VMC-050a): the next waiting craters start.
  defp job_done(:explosion, _job, _result, state), do: {:noreply, start_craters(state)}

  # A merchant's exploration map found (or not) its structure: its draw runs
  # again with the answer (VMC-044b2).
  defp job_done(:trade_locate, _job, result, state) do
    found =
      case result do
        {:ok, {x, y, z}} -> {x, y, z}
        _ -> nil
      end

    case state.trade_waiting do
      [waiting | rest] ->
        tag = waiting.tag
        waiting = %{waiting | answers: [{tag, found} | waiting.answers]}
        {:noreply, waiting_draw(%{state | trade_waiting: rest}, waiting)}

      [] ->
        {:noreply, state}
    end
  end

  defp job_done(:mob_locate, job, result, state),
    do: {:noreply, %{state | mob_located: {{job.uuid, job.request}, result}}}

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
    # An immediate group explosion may interrupt the ordinary planning fence.
    # Reject its copied store instead of overwriting the newly resolved hits.
    result =
      cond do
        Map.has_key?(pending, :base_store) and
            not Store.same?(pending.base_store, state.entities.store) ->
          {:error, {:retry, :stale_item_plan}}

        pending.acceptance_deadline != nil and
            System.monotonic_time(:millisecond) >= pending.acceptance_deadline ->
          {:error, :expired_item_step}

        true ->
          result
      end

    state = native_plan_done(state, result)

    case result do
      {:write, items, reply} ->
        # Only handoffs add or withdraw native mobs (VMC-081d).
        items =
          if Map.get(pending, :kind) in [:item_handoff_in, :item_handoff_out],
            do: Store.sync_native(items),
            else: items

        # What the owner changed since the plan copied the store still goes
        # into a frame.
        items = Store.adopt(items, state.entities.store)
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
  defp job_failed(:light_frames, job, _reason, state),
    do: {:noreply, Valimc.World.LightUpdates.failed(state, job)}

  defp job_failed({:encode, key}, _job, reason, state) do
    {waiters, encodes} = Map.pop(state.encodes, key, [])
    for from <- waiters, do: GenServer.reply(from, {:error, {:encoder_failed, reason}})
    {:noreply, %{state | encodes: encodes}}
  end

  defp job_failed(:dragon_pillars, _job, _reason, state),
    do: {:noreply, %{state | arena_retry: state.game_tick + 20}}

  defp job_failed(:handoff, _job, _reason, state) do
    Valimc.Data.Metrics.add(:item_handoff_retries)
    {:noreply, schedule_handoff_retry(state, 250)}
  end

  # A plan has adopted nothing yet: its caller may retry.
  defp job_failed(:plan, pending, _reason, state) do
    reply_item(pending.from, Error.retry(:item_plan_failed))
    {:noreply, item_plan_failed(state, pending)}
  end

  # Its mobs' pending paths give up on their own (`Navigation.receive/1`).

  defp job_failed(:trade_locate, job, reason, state),
    do: job_done(:trade_locate, job, {:error, reason}, state)

  defp job_failed(:mob_locate, job, reason, state),
    do: job_done(:mob_locate, job, {:error, reason}, state)

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

  @doc """
  Why the section does not unload now (diagnostics, VMC-081c1): `"ticket
  TYPES"`, the first work in flight that keeps it (`"busy …"`), or `"idle"`.
  """
  def unload_blocker(state) do
    cond do
      not Tickets.empty?(state.tickets) ->
        types = state.tickets.entries |> Map.keys() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
        "ticket " <> Enum.join(Enum.sort(types), "+")

      RegionStorage.busy?(state.storage) ->
        "busy storage"

      Jobs.busy?(state.jobs) ->
        kinds =
          for {kind, _} <- state.jobs.entries,
              do: if(is_tuple(kind), do: elem(kind, 0), else: kind)

        "busy jobs " <> Enum.join(Enum.uniq(Enum.map(kinds, &to_string/1)), "+")

      state.entities.handoff != nil or state.entities.portal != nil ->
        "busy items"

      map_size(state.encodes) > 0 ->
        "busy encodes"

      RegionGeneration.busy?(state.generation) ->
        if state.generation.deferred_count > 0,
          do: "busy generation calls",
          else: "busy generation wants"

      map_size(state.container_viewers.views) > 0 or map_size(state.permits.entries) > 0 ->
        "busy containers"

      true ->
        "idle"
    end
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

  # A stuck arrow or trident, or a loyal trident returning to `actor`
  # (VMC-037q).
  defp takeable?(%Body{type: type, data: %{in_ground: true, shake: 0}}, _actor)
       when type in ["minecraft:arrow", "minecraft:trident"],
       do: true

  defp takeable?(%Body{type: "minecraft:trident", data: %{returning: true, owner: owner}}, actor),
    do: owner != nil and owner.uuid == actor.uuid

  defp takeable?(_body, _actor), do: false
end
