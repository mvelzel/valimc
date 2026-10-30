defmodule Valimc.Entity.Store do
  @moduledoc """
  A region owner's entity store (VMC-077h): every entity it owns, by network
  id with a uuid index, each of a kind (`:item`, `:orb`, and every other type
  as a body, `Valimc.Entity.Body`: `:mob` living, `:object` not, VMC-043a),
  with its published view and the handoff ledger (`Valimc.Entity.Handoffs`).
  Only the owner mutates it.

  An entity keeps its network id (`Valimc.Entity.Ids`) for the life of the
  VM: a record handed over between owners carries it. Its `hops` count the
  handoffs it has made, so a permit granted before it left and came back no
  longer matches. Records are persisted one by one (`RegionStorage`), so the
  store has no count or size cap.

  Every change to an entity's record (VMC-081h) puts its uuid in `dirty`,
  the store's journal: its owner's next frame takes the journal
  (`take_dirty/1`) and writes the records it names, so a frame costs what
  changed, never a walk over the store. Changes to what no record holds (an
  entry's tick stamps, a mob's idle time, the on-fire flag) and native mobs,
  whose records are their section's (`NativeMobs.cut/2`), stay out of it.

  An item whose tick changes nothing but its counters rests (VMC-081l):
  its owner stops stepping and ageing it (`rest/3`) until something it
  depends on changes. Its age then runs on its chunk's clock (`clocks`:
  the ticks each chunk aged while it held resting items): the entry keeps
  its counters as of the clock it rested at (`rest`), and `settled/2` gives
  them as of now. Only its age moves meanwhile: an item rests with no
  pickup delay or an unlimited one and no portal cooldown. Every store path
  that changes or reads it for a change settles it (`current/4`), and every
  view change wakes it (`Spatial.put/4`).
  """
  alias Valimc.Data.Grid
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.{EntityPackets, ItemData, ItemStack, ItemTypes}
  alias Valimc.Entity.{Body, ExperienceOrbs, Ids, NativeBody, NativeMobs, Spatial, View}
  alias Valimc.Native

  # The handoff ledger: the last outgoing sequence, the one outgoing intent and
  # the receipts of incoming handoffs by source.
  @ledger %{sequence: 0, outgoing: nil, incoming: %{}}
  # `deaths`: bodies whose mob died with drops its owner has not dropped yet
  # (`take_deaths/1`, VMC-037n). `native`: the section's native mobs
  # (`Valimc.Entity.NativeMobs`, VMC-081d), nil when none of its types is
  # native; an entry of a native mob holds its resource as `native` and a
  # `NativeBody` row as its body. `dirty`: the journal, uuid => true.
  defstruct epoch: nil,
            entries: %{},
            uuids: %{},
            views: %{},
            spatial: %Valimc.Entity.Spatial{},
            ledger: @ledger,
            deaths: [],
            native: nil,
            dirty: %{},
            clocks: %{},
            aged_at: %{}

  @max_steps 32
  @bodies [:mob, :object]
  # The entity events a view keeps for its tracker (each tick sends the new
  # ones): a hurt squid's ink is 30 particles beside its sounds (VMC-043e).
  @kept_events 40

  def empty_ledger, do: @ledger

  def new, do: %__MODULE__{epoch: make_ref()}

  @doc """
  The uuids whose records changed since the last call (the journal), and the
  store without them.
  """
  def take_dirty(%__MODULE__{dirty: dirty} = state) when map_size(dirty) == 0, do: {[], state}
  def take_dirty(%__MODULE__{dirty: dirty} = state), do: {Map.keys(dirty), %{state | dirty: %{}}}

  @doc """
  Whether two stores hold the same entities, views and ledger, whatever their
  journals: a frame taken meanwhile leaves a store the same.
  """
  def same?(%__MODULE__{} = a, %__MODULE__{} = b), do: %{a | dirty: %{}} == %{b | dirty: %{}}
  def same?(a, b), do: a == b

  @doc """
  `planned`, derived from `current`'s entities elsewhere (a plan's worker),
  with `current`'s journal too: what its owner changed since it was copied
  still goes into a frame.
  """
  def adopt(%__MODULE__{} = planned, %__MODULE__{dirty: dirty}) when map_size(dirty) == 0,
    do: planned

  def adopt(%__MODULE__{} = planned, %__MODULE__{} = current),
    do: %{planned | dirty: Map.merge(planned.dirty, current.dirty)}

  # The journal with `entry`'s record changed: a native mob's is its
  # section's.
  defp dirty(dirty, %{native: ref}) when ref != nil, do: dirty
  defp dirty(dirty, %{entity: %{uuid: uuid}}), do: Map.put(dirty, uuid, true)

  @doc "Rebase worker-created items onto current motion/counters; never replace existing items."
  def merge_created(%{epoch: epoch} = current, %{epoch: epoch} = original, original),
    do: {:ok, current}

  def merge_created(current, original, proposed) do
    original_ids = Map.keys(original.entries)
    added = Map.drop(proposed.entries, original_ids)

    cond do
      current.epoch != original.epoch or proposed.epoch != original.epoch or
        proposed.ledger != original.ledger or
          Map.take(proposed.entries, original_ids) != original.entries ->
        {:error, :invalid_item_additions}

      Enum.any?(added, fn {id, entry} ->
        Map.has_key?(current.entries, id) or reserved_uuid?(current, entry.entity.uuid) or
            Map.has_key?(current.uuids, entry.entity.uuid)
      end) ->
        {:error, :duplicate_item_uuid}

      true ->
        {:ok,
         %{
           current
           | entries: Map.merge(current.entries, added),
             dirty: Enum.reduce(added, current.dirty, fn {_, e}, d -> dirty(d, e) end),
             uuids: Enum.into(added, current.uuids, fn {id, e} -> {e.entity.uuid, id} end),
             spatial:
               Enum.reduce(added, current.spatial, fn {id, _}, index ->
                 Spatial.put(index, id, nil, proposed.views[id])
               end),
             views: Map.merge(current.views, Map.take(proposed.views, Map.keys(added)))
         }}
    end
  end

  @doc """
  Advance counters and identify expired/below-world items and the orbs merged
  away (`merge_orbs/3`); removal waits for the owner's durable commit.
  """
  def age(state, ticks \\ 1, minimum_y \\ Grid.min_y(), game_tick \\ nil) do
    state = Enum.reduce(Map.keys(state.spatial.resting), state, &wake(&2, &1))

    ages = for {id, entry} <- state.entries, not native_entry?(entry), into: %{}, do: {id, ticks}
    {state, expired} = age_selected(state, ages, minimum_y, game_tick)

    budget =
      for {_, %{native: ref, entity: e}} <- state.entries,
          ref != nil,
          uniq: true,
          do: {Grid.chunk_key(e.x, e.z), ticks}

    {state, more} = age_natives(state, budget, minimum_y, game_tick)
    {state, expired ++ more}
  end

  @doc "Advance counters only in chunks with an eligible tick budget."
  def age_chunks(state, chunk_ticks, minimum_y, game_tick) do
    # Every mob is native (VMC-081d) and ages in its section, in one call:
    # only the other kinds' memberships are walked (VMC-081j).
    # Resting items age on their chunk's clock (VMC-081l): only the awake
    # ones are walked.
    memberships =
      for {chunk, ticks} <- chunk_ticks,
          is_integer(ticks) and ticks > 0,
          kind <- [:object, :item, :orb],
          ids =
            if(kind == :item,
              do: Map.get(state.spatial.awake, chunk),
              else: Map.get(state.spatial.chunks, {chunk, kind})
            ),
          ids != nil,
          do: {ids, ticks}

    count = Enum.reduce(memberships, 0, fn {ids, _}, count -> count + MapSet.size(ids) end)

    # Sparse tickets should not walk the render-loaded population. When most
    # entries tick, a direct traversal avoids rebuilding a dense set through
    # many small membership buckets; both paths select the same live entries.
    entries = state.entries

    ages =
      if count * 2 >= map_size(entries) do
        for {id, entry} <- entries,
            not native_entry?(entry),
            not Spatial.resting?(state.spatial, id),
            ticks = Map.get(chunk_ticks, Grid.chunk_key(entry.entity.x, entry.entity.z)),
            is_integer(ticks) and ticks > 0,
            into: %{},
            do: {id, ticks}
      else
        for {ids, ticks} <- memberships,
            id <- ids,
            not native_entry?(entries[id]),
            into: %{},
            do: {id, ticks}
      end

    {state, expired} = age_selected(state, ages, minimum_y, game_tick)
    {state, resting} = age_resting(state, chunk_ticks, game_tick)
    expired = resting ++ expired

    budget =
      if state.native == nil,
        do: [],
        else:
          for({chunk, ticks} <- chunk_ticks, is_integer(ticks) and ticks > 0, do: {chunk, ticks})

    {state, more} = age_natives(state, budget, minimum_y, game_tick)
    {state, expired ++ more}
  end

  # The native mobs' timers (`NativeMobs.age/4`): only those whose row or
  # events changed come back, and those done (dead and gone, or fallen
  # out of the world) expire.
  defp age_natives(%__MODULE__{native: nil} = state, _budget, _minimum_y, _game_tick),
    do: {state, []}

  defp age_natives(state, budget, minimum_y, game_tick) do
    state.native
    |> NativeMobs.age(game_tick, budget, minimum_y)
    |> Enum.reduce({state, []}, fn {id, row, events, done}, {items, expired} ->
      case items.entries[id] do
        nil ->
          {items, expired}

        entry ->
          items =
            if row == nil and events == [],
              do: items,
              else: put_body(items, id, NativeBody.merge(row || entry.body, entry.body), events)

          expired =
            if done, do: [{items.epoch, id, items.entries[id].revision} | expired], else: expired

          {items, expired}
      end
    end)
  end

  defp age_selected(state, ages, minimum_y, game_tick) do
    {state, absorbed} = merge_orbs(state, ages, game_tick)
    {state, expired} = age_entries(state, ages, minimum_y, game_tick)

    state =
      if game_tick != nil do
        entries =
          Enum.reduce(ages, state.entries, fn {id, _}, entries ->
            Map.update!(entries, id, &Map.put(&1, :aged_tick, game_tick))
          end)

        %{state | entries: entries}
      else
        state
      end

    {state, Enum.uniq(absorbed ++ expired)}
  end

  # Only eligible orbs start scans. Passive neighbours remain candidates for
  # an active scan; ticket eligibility does not make them immune to merging.
  defp merge_orbs(state, ages, game_tick) do
    scanning =
      for {id, ticks} <- ages,
          %{kind: :orb, lived: lived} = entry <- [state.entries[id]],
          game_tick == nil or Map.get(entry, :aged_tick) != game_tick,
          lived + 1 + Integer.mod(-lived, 20) <= lived + ticks,
          do: id

    if scanning == [] do
      {state, []}
    else
      # An orb's expanded box reaches at most one adjacent chunk. Reuse the
      # membership index rather than traversing render-only mobs and items.
      chunks =
        for id <- scanning,
            {x, z} = Grid.chunk_key(state.entries[id].entity.x, state.entries[id].entity.z),
            dx <- -1..1,
            dz <- -1..1,
            into: MapSet.new(),
            do: {x + dx, z + dz}

      orbs = in_chunks(state, chunks, :orb)

      before =
        Map.new(orbs, fn {id, %{entity: e} = entry} ->
          {id, %{value: entry.value, count: entry.count, age: entry.age, at: {e.x, e.y, e.z}}}
        end)

      {merged, absorbed} = ExperienceOrbs.merge(before, Enum.sort(scanning))

      state =
        Enum.reduce(merged, state, fn {id, orb}, acc ->
          if orb == before[id] do
            acc
          else
            entry = acc.entries[id]
            revision = entry.revision + 1
            entry = %{entry | count: orb.count, age: orb.age, revision: revision}
            view = %{acc.views[id] | count: orb.count, revision: revision}

            %{
              acc
              | entries: Map.put(acc.entries, id, entry),
                dirty: dirty(acc.dirty, entry),
                views: Map.put(acc.views, id, view)
            }
          end
        end)

      {state, for(id <- absorbed, do: {state.epoch, id, state.entries[id].revision})}
    end
  end

  defp age_entries(state, ages, minimum_y, game_tick) do
    Enum.reduce(ages, {state, []}, fn {id, ticks}, {items, expired} = acc ->
      case items.entries[id] do
        %{aged_tick: tick} when tick != nil and tick == game_tick ->
          acc

        %{simulated_tick: tick} when tick != nil and tick == game_tick ->
          acc

        %{kind: kind} = entry when kind in @bodies ->
          # A body can move between sibling sections during this group tick.
          # Its timers run only once, with its live state carried over.
          body = Body.tick(entry.body, ticks)
          items = if body == entry.body, do: items, else: put_body(items, id, body, [])

          expired =
            if entry.entity.y < minimum_y - 64,
              do: [{items.epoch, id, items.entries[id].revision} | expired],
              else: expired

          {idle(items, id, kind, ticks), expired}

        %{kind: :orb} = entry ->
          # An orb's age is a counter (vanilla despawns it at 6000 ticks); its
          # handles and view stay.
          age = min(entry.age + ticks, 6000)
          # Its portal cooldown runs down (VMC-026d).
          motion = %{entry.motion | portal_cooldown: max(0, entry.motion.portal_cooldown - ticks)}
          entry = %{entry | age: age, lived: entry.lived + ticks, motion: motion}

          items = %{
            items
            | entries: Map.put(items.entries, id, entry),
              dirty: dirty(items.dirty, entry)
          }

          expired =
            if age >= 6000 or entry.entity.y < minimum_y - 64,
              do: [{items.epoch, id, entry.revision} | expired],
              else: expired

          {items, expired}

        entry ->
          motion = Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity})
          next = ItemMotionState.advance(motion, ticks)

          items =
            if Map.get(entry, :motion) == next do
              items
            else
              revision = entry.revision + 1
              entry = entry |> Map.put(:motion, next) |> Map.put(:revision, revision)

              %{
                items
                | entries: Map.put(items.entries, id, entry),
                  dirty: dirty(items.dirty, entry),
                  views:
                    Map.update!(
                      items.views,
                      id,
                      &%{
                        &1
                        | revision: revision,
                          pickup_delay: next.pickup_delay,
                          merge_open: merge_open?(entry.stack.count, &1.merge_max, next)
                      }
                    )
              }
            end

          expired =
            if next.age >= 6000 or entry.entity.y < minimum_y - 64,
              do: [{items.epoch, id, items.entries[id].revision} | expired],
              else: expired

          {items, expired}
      end
    end)
  end

  # A mob's tick counters (VMC-042a): its idle time (`noActionTime`, which
  # its AI step counts up) and the ticks it lived (`tickCount`). Neither is in
  # its record, as vanilla saves neither; they leave the revision alone.
  defp idle(items, id, :mob, ticks) do
    entry = items.entries[id]

    entry =
      entry
      |> Map.put(:idle, Map.get(entry, :idle, 0) + ticks)
      |> Map.put(:lived, Map.get(entry, :lived, 0) + ticks)

    %{items | entries: Map.put(items.entries, id, entry)}
  end

  defp idle(items, id, :object, ticks) do
    entry = items.entries[id]

    if entry.body.type == "minecraft:leash_knot" do
      %{
        items
        | entries:
            Map.put(items.entries, id, Map.put(entry, :lived, Map.get(entry, :lived, 0) + ticks))
      }
    else
      items
    end
  end

  @doc "Restart the idle time of mobs `ids` (a player came within 32 blocks)."
  def reset_idle(state, ids) do
    {natives, entries} =
      Enum.reduce(ids, {[], state.entries}, fn id, {natives, entries} ->
        case entries do
          # A native mob's idle time is its section's (VMC-081d).
          %{^id => %{native: ref}} when ref != nil ->
            {[id | natives], entries}

          %{^id => %{kind: :mob} = entry} ->
            {natives, Map.put(entries, id, Map.put(entry, :idle, 0))}

          _ ->
            {natives, entries}
        end
      end)

    if natives != [], do: :ok = Native.mob_section_reset_idle(state.native.ref, natives)
    %{state | entries: entries}
  end

  @doc "Every entity's persistent record, by uuid (network ids are the VM's, never stored)."
  def records(state),
    do:
      state.entries
      |> Enum.map(fn {_, entry} -> record(settled(state, entry)) end)
      |> Enum.sort_by(& &1.uuid)

  ## Resting items (VMC-081l)

  @doc """
  Item `id`, whose last tick changed nothing but its counters, rests: its
  owner neither steps nor ages it until it wakes. `deps` are the chunks its
  tick reads, each with the publication it read (`[{chunk, publication}]`).
  Its age runs on its chunk's clock from here, which has aged for
  `game_tick` already; its record stays as it is.
  """
  def rest(state, id, deps, game_tick \\ nil) do
    case state.entries[id] do
      %{kind: :item, motion: %ItemMotionState{} = motion, entity: e} = entry
      when not is_map_key(entry, :rest) ->
        chunk = Grid.chunk_key(e.x, e.z)
        clock = Map.get(state.clocks, chunk, 0)
        due = if motion.age == -32_768, do: nil, else: clock + 6000 - motion.age

        %{
          state
          | entries: Map.put(state.entries, id, Map.put(entry, :rest, clock)),
            clocks: Map.put(state.clocks, chunk, clock),
            aged_at: Map.put_new(state.aged_at, chunk, game_tick),
            spatial: Spatial.rest(state.spatial, id, chunk, due, deps)
        }

      _ ->
        state
    end
  end

  @doc """
  `entry` with its counters as of now: a resting item's age advanced by
  the ticks its chunk aged since it rested, no longer resting. Any other
  entry as it is.
  """
  def settled(state, %{rest: base, entity: e, motion: motion} = entry) do
    entry = Map.delete(entry, :rest)

    case Map.get(state.clocks, Grid.chunk_key(e.x, e.z), base) - base do
      ticks when ticks > 0 -> %{entry | motion: ItemMotionState.advance(motion, ticks)}
      _ -> entry
    end
  end

  def settled(_state, entry), do: entry

  @doc "Item `id` wakes: settled (`settled/2`), stepped and aged again."
  def wake(state, id) do
    case state.entries[id] do
      %{rest: _} = entry ->
        settled = settled(state, entry)

        dirty =
          if settled.motion == entry.motion, do: state.dirty, else: dirty(state.dirty, settled)

        %{
          state
          | entries: Map.put(state.entries, id, settled),
            dirty: dirty,
            spatial: Spatial.wake(state.spatial, id)
        }

      _ ->
        %{state | spatial: Spatial.wake(state.spatial, id)}
    end
  end

  @doc """
  Wake the resting items whose tick might no longer change nothing: every
  one when the world border is not `border` (the border they rest under),
  else those reading a chunk whose publication (`publication` gives it by
  chunk) is not the one they rested on.
  """
  def wake_stale(state, border, publication) do
    case Spatial.stale(state.spatial, border, publication) do
      # Nothing to wake leaves the very store (most ticks).
      {[], spatial} when spatial === state.spatial -> state
      {ids, spatial} -> Enum.reduce(ids, %{state | spatial: spatial}, &wake(&2, &1))
    end
  end

  @doc "Whether the store holds resting items whose age runs (checkpoints save it)."
  def ageing_at_rest?(state), do: map_size(state.spatial.due) > 0

  # The chunk clocks of `chunk_ticks` advance, once a game tick as every
  # entity ages (`aged_at`), and the resting items whose age reaches 6000
  # expire.
  defp age_resting(%{clocks: clocks} = state, _chunk_ticks, _game_tick)
       when map_size(clocks) == 0,
       do: {state, []}

  defp age_resting(state, chunk_ticks, game_tick) do
    Enum.reduce(chunk_ticks, {state, []}, fn
      {chunk, ticks}, {acc, expired} when is_integer(ticks) and ticks > 0 ->
        case acc.clocks do
          %{^chunk => _}
          when game_tick != nil and :erlang.map_get(chunk, acc.aged_at) == game_tick ->
            {acc, expired}

          %{^chunk => clock} ->
            acc = %{
              acc
              | clocks: Map.put(acc.clocks, chunk, clock + ticks),
                aged_at: Map.put(acc.aged_at, chunk, game_tick)
            }

            gone =
              for id <- Spatial.due(acc.spatial, chunk, clock + ticks),
                  %{rest: _} = entry <- [acc.entries[id]],
                  settled(acc, entry).motion.age >= 6000,
                  do: {acc.epoch, id, entry.revision}

            {acc, gone ++ expired}

          _ ->
            {acc, expired}
        end

      _, acc ->
        acc
    end)
  end

  ## Native mobs (VMC-081d)

  @doc """
  The native mobs of `ids` leaving whole for a sibling section of the
  group: a parcel each, by id (VMC-081d).
  """
  def native_parcels(%__MODULE__{native: nil}, _ids), do: %{}

  def native_parcels(%__MODULE__{native: native}, ids) do
    for id <- ids, into: %{} do
      {:ok, parcel} = Native.mob_section_take(native.ref, [id])
      {id, parcel}
    end
  end

  @doc "Whether `entry` is a native mob's."
  def native_entry?(%{native: ref}) when ref != nil, do: true
  def native_entry?(_entry), do: false

  # A native mob's entry from its row.
  defp put_native(state, id, uuid, {x, y, z}, row, hops) do
    entry = %{
      kind: :mob,
      native: state.native.ref,
      entity: %{entity_id: id, uuid: uuid, x: x, y: y, z: z},
      body: row,
      events: [],
      event_seq: 0,
      revision: 1,
      physical_revision: 1,
      hops: hops
    }

    view = body_view(state.epoch, entry)

    %{
      state
      | entries: Map.put(state.entries, id, entry),
        dirty: dirty(state.dirty, entry),
        uuids: Map.put(state.uuids, uuid, id),
        spatial: Spatial.put(state.spatial, id, state.views[id], view),
        views: Map.put(state.views, id, view)
    }
  end

  # A mob from a sibling section of the group comes whole.
  defp build_native(state, id, %{uuid: uuid, native_parcel: parcel} = record) do
    case Native.mob_section_put(state.native.ref, parcel, id) do
      {:ok, {^id, position, row}} ->
        {:ok, put_native(state, id, uuid, position, row, Map.get(record, :hops, 0)),
         {state.epoch, id, 1}}

      {:error, _} ->
        build_native(state, id, Map.delete(record, :native_parcel))
    end
  end

  # A mob's record joins the section's mobs: in the owner at once;
  # in a plan's worker as a pending entry its owner adds when it adopts the
  # plan (`sync_native/1`).
  defp build_native(state, id, %{uuid: uuid} = record) do
    school = Map.get(record, :school)

    record =
      Map.drop(record, [:entity_id, :entity_counters, :school, :native_parcel, :on_fire])

    case Native.mob_section_insert(state.native.ref, [{id, record}], false) do
      {:ok, [{^id, position, row}]} when school != nil ->
        # A pack's fish keeps the school its spawn made.
        {leader, size} = school
        :ok = Native.mob_section_school(state.native.ref, id, leader, size)

        {:ok, put_native(state, id, uuid, position, row, Map.get(record, :hops, 0)),
         {state.epoch, id, 1}}

      {:ok, [{^id, position, row}]} ->
        {:ok, put_native(state, id, uuid, position, row, Map.get(record, :hops, 0)),
         {state.epoch, id, 1}}

      {:error, :not_owner} ->
        case Native.mob_section_row(record) do
          {:ok, {position, row, normal}} ->
            state = put_native(state, id, uuid, position, row, Map.get(record, :hops, 0))
            entry = Map.put(state.entries[id], :native_pending, normal)
            {:ok, %{state | entries: Map.put(state.entries, id, entry)}, {state.epoch, id, 1}}

          _ ->
            {:error, :invalid_item}
        end

      {:error, _} ->
        {:error, :invalid_item}
    end
  end

  @doc """
  A plan's store adopted (VMC-081d): the native mobs it added in its worker
  join the section's native mobs, and those it withdrew leave them.
  """
  def sync_native(%__MODULE__{native: nil} = state), do: state

  def sync_native(%__MODULE__{native: native} = state) do
    pending = for {id, %{native_pending: record}} <- state.entries, do: {id, record}

    state =
      case pending do
        [] ->
          state

        pending ->
          {:ok, rows} = Native.mob_section_insert(native.ref, pending, false)

          Enum.reduce(rows, state, fn {id, _position, row}, acc ->
            entry = Map.delete(acc.entries[id], :native_pending)
            entry = %{entry | body: NativeBody.merge(row, entry.body)}
            %{acc | entries: Map.put(acc.entries, id, entry)}
          end)
      end

    present =
      for {id, %{native: ref}} <- state.entries, ref != nil, into: MapSet.new(), do: id

    gone =
      for {id, _type, _position, _persistent, _alive} <- Native.mob_section_mobs(native.ref),
          not MapSet.member?(present, id),
          do: id

    if gone != [], do: Native.mob_section_remove(native.ref, gone)
    state
  end

  @doc """
  A native tick's report (VMC-081d, `Native.mob_section_tick/7`): `moved`,
  the packed physical states of the mobs that moved, mirrored into their
  entries, rows and views (no view is rebuilt, and the chunk index changes
  only when a chunk does); then each change `{id, row | nil, events,
  effects, outside}`: a new row and its events go into the entry and its
  view as a section call's do. Returns `{state, steps}`: a step for each
  mob with effects or leaving the section (`outside` its position there,
  which this store leaves to the owner's routing).
  """
  def native_tick(state, moved, changes) do
    state = native_moves(state, moved)

    Enum.reduce(changes, {state, []}, fn {id, row, events, effects, outside}, {state, steps} ->
      case state.entries[id] do
        %{native: _, entity: e, body: body} = entry ->
          row = if row == nil, do: body, else: NativeBody.merge(row, body)

          case outside do
            nil ->
              state =
                if row == body and events == [],
                  do: state,
                  else: put_body(state, id, row, events)

              step =
                effects != [] &&
                  %{
                    id: id,
                    revision: state.entries[id].revision,
                    position: {e.x, e.y, e.z},
                    body: row,
                    events: [],
                    effects: effects,
                    native: true,
                    outside: false
                  }

              {state, if(step, do: [step | steps], else: steps)}

            position ->
              step = %{
                id: id,
                revision: entry.revision,
                position: position,
                body: row,
                events: events,
                effects: effects,
                native: true,
                outside: true
              }

              {state, [step | steps]}
          end

        _ ->
          {state, steps}
      end
    end)
    |> then(fn {state, steps} -> {state, Enum.reverse(steps)} end)
  end

  @solid_mobs ["minecraft:shulker"]

  @doc "The packed physical states of moved native mobs into their entries and views."
  def native_moves(state, <<>>), do: state

  def native_moves(state, moved) do
    {entries, views, spatial} = moves(moved, state.entries, state.views, state.spatial)
    %{state | entries: entries, views: views, spatial: spatial}
  end

  defp moves(
         <<id::32-signed, x::float, y::float, z::float, yaw::float, pitch::float, head::float,
           vx::float, vy::float, vz::float, ground, rest::binary>>,
         entries,
         views,
         spatial
       ) do
    case entries do
      %{^id => %{entity: entity, body: row} = entry} ->
        on_ground = ground == 1
        velocity = {vx, vy, vz}

        row = %{
          row
          | yaw: yaw,
            pitch: pitch,
            head_yaw: head,
            velocity: velocity,
            on_ground: on_ground
        }

        moved = entity.x != x or entity.y != y or entity.z != z
        revision = entry.revision + 1
        physical = entry.physical_revision + if(moved, do: 1, else: 0)

        entry = %{
          entry
          | entity: %{entity | x: x, y: y, z: z},
            body: row,
            revision: revision,
            physical_revision: physical
        }

        old = views[id]
        chunk = Grid.chunk_key(x, z)

        view = %{
          old
          | at: {x, y, z},
            chunk: chunk,
            velocity: velocity,
            on_ground: on_ground,
            yaw: yaw,
            pitch: pitch,
            head_yaw: head,
            body: row,
            revision: revision,
            physical_revision: physical
        }

        spatial =
          if chunk != old.chunk or row.type in @solid_mobs,
            do: Spatial.put(spatial, id, old, view),
            else: spatial

        moves(rest, Map.put(entries, id, entry), Map.put(views, id, view), spatial)

      _ ->
        moves(rest, entries, views, spatial)
    end
  end

  defp moves(<<>>, entries, views, spatial), do: {entries, views, spatial}

  @doc "Native mob `id` changed (`native_change/5`'s result of a section call)."
  def native_change(state, id, {x, y, z}, row, events) do
    case state.entries[id] do
      %{native: _, entity: entity} = entry ->
        moved = {entity.x, entity.y, entity.z} != {x, y, z}

        entry = %{
          entry
          | entity: %{entity | x: x, y: y, z: z},
            physical_revision: entry.physical_revision + if(moved, do: 1, else: 0)
        }

        state
        |> put_entry(id, entry)
        |> change_body(id, row, events)

      _ ->
        state
    end
  end

  # An outside step of a native mob (a teleport, a portal, a piston): its
  # section takes the entry's place, rotation, motion and portal cooldown
  # (one leaving the section too, which its owner moves on at once); in a
  # plan's worker the row keeps them and the plan's record carries them
  # (`record/1`).
  defp native_sync(%{native: ref, native_pending: _}, _id, _position, row) when ref != nil,
    do: row

  defp native_sync(%{native: ref}, id, position, %NativeBody{} = row) do
    case Native.mob_section_sync(
           ref,
           id,
           position,
           {row.yaw, row.pitch, row.head_yaw},
           row.velocity,
           row.on_ground,
           row.portal_cooldown
         ) do
      {:ok, {_, _, {_, new}}} -> NativeBody.merge(new, row)
      {:error, _} -> row
    end
  end

  def record(%{kind: :orb, entity: entity} = entry) do
    record =
      entity
      |> Map.take([:uuid, :x, :y, :z])
      |> Map.merge(%{
        kind: :orb,
        value: entry.value,
        count: entry.count,
        age: entry.age,
        motion: entry.motion
      })

    # An imported orb's saved motion, kept for export.
    record = if entry.saved, do: Map.put(record, :saved, entry.saved), else: record
    if entry.hops > 0, do: Map.put(record, :hops, entry.hops), else: record
  end

  def record(%{native: ref, entity: entity, body: %NativeBody{} = row} = entry)
      when ref != nil do
    record =
      case entry do
        %{native_pending: pending} ->
          pending

        _ ->
          case Native.mob_section_records(ref, [entity.entity_id]) do
            [record] -> record
            [] -> raise ArgumentError, "native mob #{entity.entity_id} is missing"
          end
      end

    # The entry's place, motion and portal cooldown, which a plan's step may
    # have moved on.
    %{
      record
      | x: entity.x,
        y: entity.y,
        z: entity.z,
        rotation: {row.yaw, row.pitch, row.head_yaw},
        velocity: row.velocity,
        on_ground: row.on_ground
    }
    |> then(
      &if(row.portal_cooldown > 0,
        do: Map.put(&1, :portal_cooldown, row.portal_cooldown),
        else: Map.delete(&1, :portal_cooldown)
      )
    )
    |> Map.delete(:hops)
    |> then(&if(entry.hops > 0, do: Map.put(&1, :hops, entry.hops), else: &1))
  end

  def record(%{kind: kind, entity: entity, body: body} = entry) when kind in @bodies do
    record =
      entity
      |> Map.take([:uuid, :x, :y, :z])
      |> Map.put(:kind, kind)
      |> Map.merge(Body.record(body))

    if entry.hops > 0, do: Map.put(record, :hops, entry.hops), else: record
  end

  def record(%{kind: :item, entity: entity, stack: stack} = entry) do
    record = entity |> Map.take([:uuid, :x, :y, :z]) |> Map.merge(%{kind: :item, stack: stack})

    record =
      if Map.has_key?(entry, :motion), do: Map.put(record, :motion, entry.motion), else: record

    if entry.hops > 0, do: Map.put(record, :hops, entry.hops), else: record
  end

  @doc "The number of handoffs the entity `uuid` has made (0 if it has none or is not here)."
  def hops(state, uuid) do
    case state.uuids do
      %{^uuid => id} -> state.entries[id].hops
      _ -> 0
    end
  end

  @doc """
  Remove the entities of `handles` for a handoff: their records, each with its
  network id and one more hop.
  """
  def withdraw(state, handles) do
    Enum.reduce_while(handles, {:ok, state, []}, fn {epoch, id, revision}, {:ok, current, acc} ->
      # A native mob's section keeps it: its caller takes it whole (a
      # sibling's parcel) or its plan's adoption lets it go (`sync_native/1`).
      with {:ok, entry} <- current(current, epoch, id, revision),
           {:ok, next} <- remove(current, epoch, id, revision, false) do
        record = entry |> record() |> Map.merge(%{entity_id: id, hops: entry.hops + 1})
        # The on-fire flag its observers were shown travels with it (VMC-034n4e).
        record =
          if entry[:on_fire] == nil, do: record, else: Map.put(record, :on_fire, entry.on_fire)

        {:cont, {:ok, next, [record | acc]}}
      else
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, next, records} -> {:ok, next, Enum.sort_by(records, & &1.uuid)}
      error -> error
    end
  end

  def restore(key, records, ledger \\ @ledger, native \\ nil)

  def restore(key, records, %{sequence: _, outgoing: _, incoming: _} = ledger, native)
      when is_list(records) do
    begin(fn ->
      # Mobs join the section's mobs together, as
      # written (the log and checkpoint hold their records).
      Enum.reduce_while(records, {:ok, %{new() | ledger: ledger}, []}, fn record,
                                                                          {:ok, state, mobs} ->
        with true <- valid_record?(key, record) and not Map.has_key?(state.uuids, record.uuid),
             {:ok, id} <- next_id(record) do
          if native != nil and record.kind == :mob do
            {:cont,
             {:ok, %{state | uuids: Map.put(state.uuids, record.uuid, id)}, [{id, record} | mobs]}}
          else
            case build_record(state, id, record) do
              {:ok, next, _} -> {:cont, {:ok, next, mobs}}
              _ -> {:halt, {:error, :invalid_item_file}}
            end
          end
        else
          _ -> {:halt, {:error, :invalid_item_file}}
        end
      end)
      |> case do
        {:ok, state, []} ->
          {:ok, %{state | native: native}}

        {:ok, state, mobs} ->
          state = %{state | native: native}
          mobs = Enum.reverse(mobs)

          case Native.mob_section_insert(native.ref, mobs, true) do
            {:ok, rows} ->
              records = Map.new(mobs)

              {:ok,
               Enum.reduce(rows, state, fn {id, position, row}, acc ->
                 record = records[id]
                 put_native(acc, id, record.uuid, position, row, Map.get(record, :hops, 0))
               end)}

            {:error, _} ->
              {:error, :invalid_item_file}
          end

        error ->
          error
      end
    end)
  end

  def restore(_, _, _, _), do: {:error, :invalid_item_file}

  @doc "Whether `record` is an entity record this store would hold in region `key`."
  def valid_record?(key, %{kind: :orb, uuid: <<_::128>>, x: x, y: y, z: z} = record) do
    %{value: value, count: count, age: age} = record

    valid_position?({x, y, z}) and valid_hops?(record) and
      Grid.region_key(Grid.chunk_key(x, z)) == key and
      is_integer(value) and value in 1..32_767 and is_integer(count) and count >= 1 and
      is_integer(age) and age in -32_768..5_999 and saved?(Map.get(record, :saved)) and
      valid_record_motion?(record)
  end

  def valid_record?(key, %{kind: kind, uuid: <<_::128>>, x: x, y: y, z: z} = record)
      when kind in @bodies do
    valid_position?({x, y, z}) and valid_hops?(record) and
      Grid.region_key(Grid.chunk_key(x, z)) == key and
      match?({:ok, %Body{}}, Body.restore(record)) and Body.kind(record.type) == kind
  end

  def valid_record?(key, %{uuid: <<_::128>>, x: x, y: y, z: z, stack: stack} = record) do
    Map.get(record, :kind, :item) == :item and valid_position?({x, y, z}) and
      valid_record_motion?(record) and valid_hops?(record) and
      Grid.region_key(Grid.chunk_key(x, z)) == key and
      match?({:ok, _}, metadata(1, stack))
  end

  def valid_record?(_, _), do: false

  defp saved?(nil), do: true

  defp saved?(%{velocity: {vx, vy, vz}, on_ground: on_ground, no_gravity: no_gravity}),
    do: Enum.all?([vx, vy, vz], &is_float/1) and is_boolean(on_ground) and is_boolean(no_gravity)

  defp saved?(_), do: false

  defp valid_hops?(record) do
    case Map.get(record, :hops, 0) do
      hops when is_integer(hops) and hops >= 0 -> true
      _ -> false
    end
  end

  # A record's entity, with the on-fire flag a handoff carried.
  defp adopt(state, id, record) do
    with {:ok, next, handle} <- build_record(state, id, record) do
      case Map.get(record, :on_fire) do
        nil -> {:ok, next, handle}
        on_fire -> {:ok, flag(next, id, on_fire), handle}
      end
    end
  end

  defp flag(state, id, on_fire) do
    entry = state.entries[id]

    metadata =
      case entry do
        %{kind: :orb} ->
          orb_metadata(id, entry.value, on_fire)

        %{kind: :item} ->
          {:ok, packet} = metadata(id, entry.stack, entry.no_gravity, on_fire)
          packet
      end

    %{
      state
      | entries: Map.put(state.entries, id, Map.put(entry, :on_fire, on_fire)),
        views: Map.update!(state.views, id, &%{&1 | metadata: metadata})
    }
  end

  defp build_record(%{native: %NativeMobs{}} = state, id, %{kind: :mob, type: type} = record)
       when is_binary(type),
       do: build_native(state, id, record)

  defp build_record(state, id, %{kind: kind, uuid: uuid, x: x, y: y, z: z} = record)
       when kind in @bodies do
    with {:ok, body} <- Body.restore(record) do
      entry = %{
        kind: kind,
        entity: %{entity_id: id, uuid: uuid, x: x, y: y, z: z},
        body: body,
        events: [],
        event_seq: 0,
        revision: 1,
        physical_revision: 1,
        hops: Map.get(record, :hops, 0)
      }

      view = body_view(state.epoch, entry)

      {:ok,
       %{
         state
         | entries: Map.put(state.entries, id, entry),
           dirty: dirty(state.dirty, entry),
           uuids: Map.put(state.uuids, uuid, id),
           spatial: Spatial.put(state.spatial, id, state.views[id], view),
           views: Map.put(state.views, id, view)
       }, {state.epoch, id, 1}}
    end
  end

  defp build_record(state, id, %{kind: :orb} = record) do
    %{uuid: uuid, x: x, y: y, z: z, value: value} = record
    motion = orb_motion(record)
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z, velocity: motion.velocity}
    hops = Map.get(record, :hops, 0)
    # Orbs move (VMC-077i): gravity, and the pull toward the player they follow.
    metadata = orb_metadata(id, value, nil)

    view =
      :orb
      |> View.new(Map.put(entity, :on_ground, motion.on_ground), metadata, state.epoch, hops)
      |> Map.merge(%{revision: 1, physical_revision: 1, value: value, count: record.count})
      # The XP pickup request's fence (VMC-077i's protocol); an orb entity needs none.
      |> Map.put(:consumed, 0)

    entry = %{
      kind: :orb,
      entity: entity,
      value: value,
      count: record.count,
      age: record.age,
      lived: 0,
      motion: motion,
      saved: Map.get(record, :saved),
      revision: 1,
      physical_revision: 1,
      hops: hops
    }

    {:ok,
     %{
       state
       | entries: Map.put(state.entries, id, entry),
         dirty: dirty(state.dirty, entry),
         uuids: Map.put(state.uuids, uuid, id),
         spatial: Spatial.put(state.spatial, id, state.views[id], view),
         views: Map.put(state.views, id, view)
     }, {state.epoch, id, 1}}
  end

  defp build_record(state, id, %{uuid: uuid, x: x, y: y, z: z, stack: stack} = record),
    do:
      build_entity(
        state,
        stack,
        {x, y, z},
        id,
        uuid,
        Map.get(record, :motion),
        record[:hops] || 0
      )

  # A record whose fields are not what the store wrote is an invalid file.
  defp begin(fun) do
    fun.()
  rescue
    ArgumentError -> {:error, :invalid_item_file}
    FunctionClauseError -> {:error, :invalid_item_file}
  end

  def find(state, <<_::128>> = uuid) do
    case state.uuids do
      %{^uuid => id} -> {:ok, {state.epoch, id, state.entries[id].revision}}
      _ -> {:error, :missing_item}
    end
  end

  def find(_, _), do: {:error, :invalid_item_uuid}

  def create(state, key, stack, {x, y, z} = position) do
    cond do
      not valid_position?(position) ->
        {:error, :invalid_item_position}

      Grid.region_key(Grid.chunk_key(x, z)) != key ->
        {:error, :wrong_region}

      true ->
        build_new(state, stack, {x, y, z})
    end
  end

  def create(_, _, _, _), do: {:error, :invalid_item_position}

  @doc """
  Creates the entity of a stable-UUID record (a player's drop, a handed-over
  entity, an awarded orb). A record handed over by another owner keeps its
  `entity_id`.
  """
  def create_record(state, key, %{uuid: <<_::128>> = uuid, x: x, y: y, z: z} = record) do
    cond do
      not valid_position?({x, y, z}) ->
        {:error, :invalid_item_position}

      Grid.region_key(Grid.chunk_key(x, z)) != key ->
        {:error, :wrong_region}

      not valid_record?(key, record) ->
        {:error, :invalid_item}

      Map.has_key?(state.uuids, uuid) ->
        {:error, :duplicate_item_uuid}

      reserved_uuid?(state, uuid) ->
        {:error, :item_handoff_busy}

      true ->
        with {:ok, id} <- record_id(state, record), do: adopt(state, id, record)
    end
  end

  def create_record(_, _, _), do: {:error, :invalid_item}

  # The id a handed-over record carries, unless this store already uses it.
  defp record_id(state, %{entity_id: id} = record) when is_integer(id) do
    if Ids.valid?(id) and Ids.valid?(id + id_span(record) - 1) and
         Enum.all?(id..(id + id_span(record) - 1), &(not Map.has_key?(state.entries, &1))),
       do: {:ok, id},
       else: next_id(record)
  end

  defp record_id(_state, record), do: next_id(record)

  defp next_id(record), do: Ids.next(id_span(record))
  defp id_span(%{type: "minecraft:ender_dragon"}), do: Valimc.Entity.Dragon.id_span()
  defp id_span(_record), do: 1

  @doc "Take one unit of the orb `uuid` of `value` (an XP pickup): removed with its last."
  def take_orb(state, uuid, value) do
    with {:ok, {epoch, id, revision}} <- find(state, uuid),
         %{kind: :orb, value: ^value, count: count} = entry when count > 0 <- state.entries[id] do
      if count == 1 do
        with {:ok, next} <- remove(state, epoch, id, revision), do: {:ok, next, id}
      else
        entry = %{entry | count: count - 1, revision: revision + 1}

        view = %{
          state.views[id]
          | count: count - 1,
            revision: revision + 1
        }

        {:ok,
         %{
           state
           | entries: Map.put(state.entries, id, entry),
             dirty: dirty(state.dirty, entry),
             spatial: Spatial.put(state.spatial, id, state.views[id], view),
             views: Map.put(state.views, id, view)
         }, id}
      end
    else
      _ -> {:error, :stale_orb}
    end
  end

  def replace(state, epoch, id, revision, stack) do
    with {:ok, entry} <- current_item(state, epoch, id, revision),
         {:ok, metadata} <- metadata(id, stack, entry.no_gravity, entry[:on_fire]) do
      if stack == entry.stack do
        {:ok, state, {epoch, id, revision}}
      else
        view =
          %{
            state.views[id]
            | revision: revision + 1,
              physical_revision: entry.physical_revision + 1,
              metadata: metadata,
              metadata_revision: state.views[id].metadata_revision + 1
          }
          |> Map.merge(
            merge_hints(
              stack,
              Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity})
            )
          )

        entry = %{
          entry
          | stack: stack,
            revision: revision + 1,
            physical_revision: entry.physical_revision + 1
        }

        next = %{
          state
          | entries: Map.put(state.entries, id, entry),
            dirty: dirty(state.dirty, entry),
            spatial: Spatial.put(state.spatial, id, state.views[id], view),
            views: Map.put(state.views, id, view)
        }

        {:ok, next, {epoch, id, revision + 1}}
      end
    end
  end

  def remove(state, epoch, id, revision, native \\ true) do
    with {:ok, entry} <- current(state, epoch, id, revision) do
      # In a plan's worker the native mob stays until the plan is adopted
      # (`sync_native/1`).
      if native and native_entry?(entry) and not Map.has_key?(entry, :native_pending),
        do: Native.mob_section_remove(entry.native, [id])

      {:ok,
       %{
         state
         | entries: Map.delete(state.entries, id),
           dirty: dirty(state.dirty, entry),
           uuids: Map.delete(state.uuids, entry.entity.uuid),
           spatial: Spatial.put(state.spatial, id, state.views[id], nil),
           views: Map.delete(state.views, id)
       }}
    end
  end

  @doc "Atomic bounded steps from a trusted owner; geometry/clock admission belongs to the caller."
  def advance(state, key, epoch, steps) when is_list(steps) do
    steps = Enum.take(steps, @max_steps + 1)

    cond do
      epoch != state.epoch ->
        Valimc.Data.Error.retry(:stale_owner)

      length(steps) not in 1..@max_steps or
          length(Enum.uniq_by(steps, &Map.get(&1, :id))) != length(steps) ->
        {:error, :invalid_item_steps}

      true ->
        Enum.reduce_while(steps, {:ok, state, []}, fn step, {:ok, items, handles} ->
          case advance_one(items, key, step) do
            {:ok, next, handle} -> {:cont, {:ok, next, [handle | handles]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, items, handles} -> {:ok, items, Enum.reverse(handles)}
          error -> error
        end
    end
  rescue
    _ -> {:error, :invalid_item_steps}
  end

  def advance(_, _, _, _), do: {:error, :invalid_item_steps}

  # An item's step and an orb's (VMC-077i) change different fields.
  defp advance_one(state, key, %{id: id} = step) do
    case state.entries do
      %{^id => %{kind: :orb}} -> advance_orb(state, key, step)
      %{^id => %{kind: kind}} when kind in @bodies -> advance_body(state, key, step)
      _ -> advance_item(state, key, step)
    end
  end

  defp advance_one(_, _, _), do: {:error, :invalid_item_steps}

  defp advance_orb(
         state,
         key,
         %{id: id, revision: revision, position: {x, y, z}, motion: motion} = step
       ) do
    with {:ok, entry} <- current(state, state.epoch, id, revision),
         true <- valid_position?({x, y, z}) and ItemMotionState.valid?(motion),
         true <- Grid.region_key(Grid.chunk_key(x, z)) == key do
      entity = Map.merge(entry.entity, %{x: x, y: y, z: z, velocity: motion.velocity})
      on_fire = on_fire(step, entry)

      if entity == entry.entity and entry.motion == motion and on_fire == entry[:on_fire] do
        {:ok, state, {state.epoch, id, revision}}
      else
        physical_revision =
          entry.physical_revision +
            if(entity != entry.entity or motion.on_ground != entry.motion.on_ground,
              do: 1,
              else: 0
            )

        old = state.views[id]

        metadata =
          if on_fire == entry[:on_fire],
            do: old.metadata,
            else: orb_metadata(id, entry.value, on_fire)

        view = %{
          old
          | revision: revision + 1,
            physical_revision: physical_revision,
            at: {x, y, z},
            chunk: Grid.chunk_key(x, z),
            velocity: motion.velocity,
            on_ground: motion.on_ground,
            metadata: metadata,
            metadata_revision:
              old.metadata_revision + if(metadata == old.metadata, do: 0, else: 1)
        }

        entry =
          %{
            entry
            | entity: entity,
              motion: motion,
              revision: revision + 1,
              physical_revision: physical_revision
          }
          |> Map.put(:on_fire, on_fire)

        {:ok,
         %{
           state
           | entries: Map.put(state.entries, id, entry),
             dirty: dirty(state.dirty, entry),
             spatial: Spatial.put(state.spatial, id, state.views[id], view),
             views: Map.put(state.views, id, view)
         }, {state.epoch, id, revision + 1}}
      end
    else
      false -> {:error, :invalid_item_step}
      error -> error
    end
  end

  defp advance_item(
         state,
         key,
         %{id: id, revision: revision, position: {x, y, z}, motion: motion} = step
       ) do
    with {:ok, entry} <- current_item(state, state.epoch, id, revision),
         true <- valid_position?({x, y, z}) and ItemMotionState.valid?(motion),
         true <- Grid.region_key(Grid.chunk_key(x, z)) == key do
      # A resting item's step was made from its entry as it rested: its
      # counters are its settled ones (VMC-081l).
      motion =
        if is_map_key(state.entries[id], :rest),
          do: %{
            motion
            | age: entry.motion.age,
              pickup_delay: entry.motion.pickup_delay,
              portal_cooldown: entry.motion.portal_cooldown
          },
          else: motion

      entity = Map.merge(entry.entity, %{x: x, y: y, z: z, velocity: motion.velocity})
      old = state.views[id]
      on_fire = on_fire(step, entry)

      metadata =
        if motion.no_gravity == entry.no_gravity and on_fire == entry[:on_fire] do
          old.metadata
        else
          {:ok, packet} = metadata(id, entry.stack, motion.no_gravity, on_fire)
          packet
        end

      if entity == entry.entity and Map.get(entry, :motion) == motion and
           on_fire == entry[:on_fire] do
        {:ok, state, {state.epoch, id, revision}}
      else
        physical_revision =
          entry.physical_revision +
            if(
              entity != entry.entity or motion.no_gravity != entry.no_gravity or
                motion.on_ground != Map.get(Map.get(entry, :motion, %{}), :on_ground, false),
              do: 1,
              else: 0
            )

        view = %{
          old
          | revision: revision + 1,
            physical_revision: physical_revision,
            at: {x, y, z},
            pickup_delay: motion.pickup_delay,
            merge_open: merge_open?(entry.stack.count, state.views[id].merge_max, motion),
            chunk: Grid.chunk_key(x, z),
            velocity: motion.velocity,
            on_ground: motion.on_ground,
            metadata: metadata,
            metadata_revision:
              old.metadata_revision + if(metadata == old.metadata, do: 0, else: 1)
        }

        entry =
          %{
            entry
            | entity: entity,
              revision: revision + 1,
              no_gravity: motion.no_gravity,
              physical_revision: physical_revision
          }
          |> Map.merge(%{motion: motion, on_fire: on_fire})

        {:ok,
         %{
           state
           | entries: Map.put(state.entries, id, entry),
             dirty: dirty(state.dirty, entry),
             spatial: Spatial.put(state.spatial, id, state.views[id], view),
             views: Map.put(state.views, id, view)
         }, {state.epoch, id, revision + 1}}
      end
    else
      false -> {:error, :invalid_item_step}
      error -> error
    end
  end

  # A body moved: a teleport (with its rotation when the step names one), a
  # mob's tick (its new body and entity events, VMC-015i) or a handoff's step.
  defp advance_body(state, key, %{id: id, revision: revision, position: {x, y, z}} = step) do
    with {:ok, entry} <- current(state, state.epoch, id, revision),
         true <- valid_position?({x, y, z}) and Grid.region_key(Grid.chunk_key(x, z)) == key do
      body =
        case step do
          %{body: %Body{} = body} ->
            body

          # A native mob's own tick: its section holds the step already.
          %{native: true, body: %NativeBody{} = row} ->
            NativeBody.merge(row, entry.body)

          %{body: %NativeBody{} = row} ->
            native_sync(entry, id, {x, y, z}, NativeBody.merge(row, entry.body))

          %{rotation: {yaw, pitch}} when is_map_key(entry, :native) ->
            native_sync(entry, id, {x, y, z}, %{
              entry.body
              | yaw: yaw,
                pitch: pitch,
                head_yaw: yaw
            })

          %{rotation: {yaw, pitch}} ->
            %{entry.body | yaw: yaw, pitch: pitch, head_yaw: yaw}

          _ when is_map_key(entry, :native) ->
            native_sync(entry, id, {x, y, z}, entry.body)

          _ ->
            entry.body
        end

      moved = {x, y, z} != {entry.entity.x, entry.entity.y, entry.entity.z}

      entry = %{
        entry
        | entity: %{entry.entity | x: x, y: y, z: z},
          physical_revision: entry.physical_revision + if(moved, do: 1, else: 0)
      }

      # A thinking mob's idle time is its AI's (`noActionTime`, VMC-041a).
      entry = if is_map_key(step, :idle), do: Map.put(entry, :idle, step.idle), else: entry

      state = %{
        state
        | entries: Map.put(state.entries, id, entry),
          dirty: dirty(state.dirty, entry)
      }

      {:ok, put_body(state, id, body, Map.get(step, :events, [])),
       {state.epoch, id, revision + 1}}
    else
      false -> {:error, :invalid_item_step}
      error -> error
    end
  end

  @doc """
  The `advance/4` step teleporting entity `id` at `revision` to `position`
  (VMC-043a): a body faces `rotation` (`{yaw, pitch}`, or as it faced when
  nil); an item or an orb (VMC-043a1) stops and lands, as `TeleportCommand`
  leaves an absolute teleport's target.
  """
  def teleport_step(state, id, revision, position, rotation) do
    step = %{id: id, revision: revision, position: position}

    case state.entries[id] do
      %{kind: kind} = entry when kind in [:item, :orb] ->
        motion = Map.get(entry, :motion) || %ItemMotionState{no_gravity: entry.no_gravity}
        Map.put(step, :motion, %{motion | velocity: {0.0, 0.0, 0.0}, on_ground: true})

      _ ->
        Map.put(step, :rotation, rotation)
    end
  end

  @doc """
  A body's own tick moved it (VMC-050a): entity `id` at `revision` is now at
  `{x, y, z}` (in section `key`) with `body` (its motion and data), its
  `events` stamped for its tracker. `{:ok, state, handle}` or an error.
  """
  def step_body(state, key, id, revision, {x, y, z}, %Body{} = body, events \\ []) do
    with {:ok, %{kind: kind} = entry} when kind in @bodies <-
           current(state, state.epoch, id, revision),
         true <- valid_position?({x, y, z}) and Grid.region_key(Grid.chunk_key(x, z)) == key do
      moved = {entry.entity.x, entry.entity.y, entry.entity.z} != {x, y, z}
      entry = %{entry | entity: %{entry.entity | x: x, y: y, z: z}}

      entry =
        if moved, do: %{entry | physical_revision: entry.physical_revision + 1}, else: entry

      state = put_entry(state, id, entry) |> put_body(id, body, events)
      {:ok, state, {state.epoch, id, state.entries[id].revision}}
    else
      {:ok, _} -> {:error, :missing_item}
      false -> {:error, :invalid_item_step}
      error -> error
    end
  end

  @doc "Whether this entry has already simulated on a non-nil group tick."
  def simulated?(entry, tick), do: tick != nil and Map.get(entry, :simulated_tick) == tick

  @doc "Record successful simulation without changing revisions, views or durable records."
  def mark_simulated(state, _ids, nil), do: state

  def mark_simulated(state, ids, tick) do
    entries =
      Enum.reduce(ids, state.entries, fn id, entries ->
        case entries do
          %{^id => entry} -> Map.put(entries, id, Map.put(entry, :simulated_tick, tick))
          _ -> entries
        end
      end)

    %{state | entries: entries}
  end

  @doc "Restore same-process live state and unsaved lifecycle counters after adoption."
  def restore_live(state, id, body, counters \\ %{}) do
    state =
      if match?(%Body{}, body) and not native_entry?(state.entries[id]),
        do: change_body(state, id, body),
        else: state

    entry =
      Map.merge(
        state.entries[id],
        Map.take(counters, [:idle, :lived, :aged_tick, :simulated_tick, :knot_checks])
      )

    %{state | entries: Map.put(state.entries, id, entry)}
  end

  @doc "Entity `id`'s body changes to `body` with `events` (a hit, a push): the new state."
  def change_body(state, id, body, events \\ [])

  def change_body(state, id, %NativeBody{} = row, events) do
    case state.entries[id] do
      %{kind: :mob, native: _} = entry ->
        state = put_body(state, id, NativeBody.merge(row, entry.body), events)
        if row.death, do: %{state | deaths: [id | state.deaths]}, else: state

      _ ->
        state
    end
  end

  def change_body(state, id, %Body{} = body, events) do
    case state.entries[id] do
      %{kind: kind} when kind in @bodies ->
        state = put_body(state, id, body, events)

        case body do
          %Body{mob: %{death: death}} when death != nil -> %{state | deaths: [id | state.deaths]}
          _ -> state
        end

      _ ->
        state
    end
  end

  @doc "A revision-fenced entity change inside its owner (including sibling section effects)."
  def change_entry(state, id, revision, change) do
    with {:ok, entry} <- current(state, state.epoch, id, revision) do
      case change do
        :keep ->
          {:ok, state}

        :remove ->
          remove(state, state.epoch, id, revision)

        {:body, %Body{} = body, events} ->
          {:ok, change_body(state, id, body, events)}

        {:native, position, row, events} ->
          {:ok, native_change(state, id, position, row, events)}

        # A native mob's lead (VMC-081d, `Valimc.Entity.Leashes`).
        {:leash, leash} ->
          case Native.mob_section_leash(entry.native, id, leash) do
            {:ok, {_, events, {position, row}}} ->
              {:ok, native_change(state, id, position, row, events)}

            {:error, _} = error ->
              error
          end

        {:motion, %ItemMotionState{} = motion} ->
          %{entity: %{x: x, y: y, z: z}} = entry
          step = %{id: id, revision: revision, position: {x, y, z}, motion: motion}
          key = Grid.region_key(Grid.chunk_key(x, z))
          with {:ok, next, _} <- advance(state, key, state.epoch, [step]), do: {:ok, next}
      end
    end
  end

  @doc """
  The deaths bodies left since the last call, oldest first, each
  `{death, position}` (`Entity.Combat`'s death and where the body died), and
  the store with them taken.
  """
  def take_deaths(%__MODULE__{deaths: []} = state), do: {state, []}

  def take_deaths(state) do
    {state, deaths} =
      state.deaths
      |> Enum.reverse()
      |> Enum.uniq()
      |> Enum.reduce({state, []}, fn id, {acc, deaths} ->
        case acc.entries[id] do
          %{native: ref, body: %NativeBody{death: true} = row} ->
            case Native.mob_section_deaths(ref, [id]) do
              [{^id, death, position}] ->
                acc = put_body(acc, id, %{row | death: false}, [])
                {acc, [{death, position} | deaths]}

              # Taken already (a sibling's copy of this store resolved it
              # first): the row changes alike, so revisions stay in step.
              _ ->
                {put_body(acc, id, %{row | death: false}, []), deaths}
            end

          %{body: %Body{mob: %{death: death} = mob} = body, entity: entity} when death != nil ->
            acc = put_body(acc, id, %{body | mob: %{mob | death: nil}}, [])
            {acc, [{death, {entity.x, entity.y, entity.z}} | deaths]}

          _ ->
            {acc, deaths}
        end
      end)

    {%{state | deaths: []}, Enum.reverse(deaths)}
  end

  @doc """
  The persistent record of a new body at `{x, y, z}` with `uuid` (`/summon`),
  for `create_record/3`.
  """
  def body_record(%Body{} = body, <<_::128>> = uuid, {x, y, z}),
    do: Map.merge(%{kind: Body.kind(body.type), uuid: uuid, x: x, y: y, z: z}, Body.record(body))

  @doc """
  `/kill` of entity `id`: a mob starts dying (its hurt and death events go
  to its tracker), every other entity is removed. `{:ok, state}` or
  `{:error, :missing_item}`.
  """
  def kill(state, id) do
    case state.entries[id] do
      # The dragon is removed (`Body.kill/1`): its death is its actor's.
      %{native: ref, body: %{type: "minecraft:ender_dragon"}, revision: revision}
      when ref != nil ->
        remove(state, state.epoch, id, revision)

      %{native: ref} ->
        case Native.mob_section_kill(ref, id) do
          {:ok, {true, events, {position, row}}} ->
            {:ok, native_change(state, id, position, row, events)}

          {:ok, {false, _, _}} ->
            {:ok, state}

          {:error, _} ->
            {:error, :missing_item}
        end

      %{revision: revision} ->
        remove(state, state.epoch, id, revision)

      nil ->
        {:error, :missing_item}
    end
  end

  # A body's new state and events, with its view rebuilt.
  defp put_body(state, id, body, events) do
    entry = state.entries[id]
    seq = entry.event_seq

    stamped =
      Enum.with_index(events, fn event, index ->
        {seq + index + 1, Body.event_packet(id, event, entry.entity)}
      end)

    entry = %{
      entry
      | body: body,
        events: Enum.take(entry.events ++ stamped, -@kept_events),
        event_seq: seq + length(events),
        revision: entry.revision + 1
    }

    put_entry(state, id, entry)
  end

  defp put_entry(state, id, entry) do
    view = body_view(state.epoch, entry, state.views[id])

    %{
      state
      | entries: Map.put(state.entries, id, entry),
        dirty: dirty(state.dirty, entry),
        spatial: Spatial.put(state.spatial, id, state.views[id], view),
        views: Map.put(state.views, id, view)
    }
  end

  @doc "Live authoritative entities of a kind in selected chunks."
  def in_chunks(state, chunks, kind),
    do: Spatial.in_chunks(state.spatial, state.entries, chunks, kind)

  @doc "How many entities of `kind` the chunk index holds in `chunks`."
  def count_in_chunks(state, chunks, kind),
    do: Spatial.count_in_chunks(state.spatial, chunks, kind)

  @doc "Solid entity colliders intersecting an area, with their live entries."
  def colliders(state, area),
    do: Spatial.colliders(state.spatial, state.entries, area)

  @doc "Whether this owner's store contains a body of `type`."
  def has_type?(state, type), do: Spatial.has_type?(state.spatial, type)

  # A body's view: what every view has, the pairing packets as its metadata
  # (kept while what they show is unchanged), its type and rotation, its body
  # (trackers send what changed) and its latest entity events.
  defp body_view(epoch, %{entity: entity, body: body} = entry, previous \\ nil) do
    position = Map.merge(entity, %{velocity: body.velocity, on_ground: body.on_ground})

    metadata =
      case previous do
        %{body: old, metadata: metadata} when old.type == body.type ->
          if Body.shown(old) == Body.shown(body),
            do: metadata,
            else: Body.pairing(entity.entity_id, body)

        _ ->
          Body.pairing(entity.entity_id, body)
      end

    entry.kind
    |> View.new(position, metadata, epoch, entry.hops)
    |> Map.merge(%{
      revision: entry.revision,
      physical_revision: entry.physical_revision,
      type: body.type,
      yaw: body.yaw,
      pitch: body.pitch,
      head_yaw: body.head_yaw,
      body: body,
      events: entry.events,
      alive: Body.alive?(body)
    })
  end

  defp current_item(state, epoch, id, revision) do
    case current(state, epoch, id, revision) do
      {:ok, %{kind: :item}} = found -> found
      {:ok, _} -> {:error, :missing_item}
      error -> error
    end
  end

  defp current(state, epoch, id, revision) do
    cond do
      epoch != state.epoch -> Valimc.Data.Error.retry(:stale_owner)
      not Map.has_key?(state.entries, id) -> {:error, :missing_item}
      state.entries[id].revision != revision -> {:error, :stale_item}
      true -> {:ok, settled(state, state.entries[id])}
    end
  end

  defp build_new(state, stack, {x, y, z}) do
    # Validate before allocating IDs/entropy. IDs share the VM-wide source used by players.
    with {:ok, _} <- metadata(1, stack),
         {:ok, id} <- Ids.next() do
      build_entity(state, stack, {x, y, z}, id, :crypto.strong_rand_bytes(16))
    end
  end

  defp build_entity(state, stack, position, id, uuid, motion \\ nil, hops \\ 0)

  defp build_entity(state, stack, {x, y, z}, id, uuid, motion, hops)
       when id in 1..2_147_483_647 do
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z}
    entity = if motion, do: Map.put(entity, :velocity, motion.velocity), else: entity
    no_gravity = if motion, do: motion.no_gravity, else: true
    on_ground = if motion, do: motion.on_ground, else: false
    {:ok, metadata} = metadata(id, stack, no_gravity)

    base =
      View.new(
        :item,
        Map.put(entity, :on_ground, on_ground),
        metadata,
        state.epoch,
        hops
      )

    view =
      base
      |> Map.merge(%{
        revision: 1,
        physical_revision: 1,
        pickup_delay: if(motion, do: motion.pickup_delay, else: 0)
      })
      |> Map.merge(merge_hints(stack, motion || %ItemMotionState{no_gravity: no_gravity}))

    entry = %{
      kind: :item,
      entity: entity,
      stack: stack,
      revision: 1,
      physical_revision: 1,
      no_gravity: no_gravity,
      hops: hops
    }

    entry = if motion, do: Map.put(entry, :motion, motion), else: entry

    next = %{
      state
      | entries: Map.put(state.entries, id, entry),
        dirty: dirty(state.dirty, entry),
        uuids: Map.put(state.uuids, uuid, id),
        spatial: Spatial.put(state.spatial, id, state.views[id], view),
        views: Map.put(state.views, id, view)
    }

    {:ok, next, {state.epoch, id, 1}}
  end

  defp build_entity(_, _, _, _, _, _, _), do: {:error, :entity_id_exhausted}

  # What merging and selection read of an item's view: its stack's identity
  # and space, and its name (`ItemEntity.getName`, VMC-043a1).
  defp merge_hints(stack, motion),
    do: %{
      item_name: ItemData.item_name(stack),
      merge_key:
        :crypto.hash(
          :sha256,
          :erlang.term_to_binary(ItemStack.identity_key(stack), [:deterministic])
        ),
      count: stack.count,
      merge_max: ItemStack.max_stack_size(stack),
      merge_open: merge_open?(stack.count, ItemStack.max_stack_size(stack), motion)
    }

  defp merge_open?(count, maximum, motion),
    do:
      motion.age != -32768 and motion.age < 6000 and
        motion.pickup_delay != 32767 and count < maximum

  @doc "Whether `uuid` is in the outgoing handoff, so it cannot arrive back yet."
  def reserved_uuid?(%{ledger: %{outgoing: %{records: records}}}, uuid),
    do: Enum.any?(records, &(&1.uuid == uuid))

  def reserved_uuid?(_, _), do: false

  # An orb's motion: its record's, an imported orb's saved one, or at rest.
  defp orb_motion(%{motion: %ItemMotionState{} = motion}), do: motion

  defp orb_motion(%{saved: %{velocity: velocity, on_ground: on_ground}}),
    do: %ItemMotionState{velocity: velocity, on_ground: on_ground}

  defp orb_motion(_record), do: %ItemMotionState{}

  defp valid_record_motion?(record) do
    case Map.fetch(record, :motion) do
      :error -> true
      {:ok, motion} -> ItemMotionState.valid?(motion)
    end
  end

  defp metadata(id, stack, no_gravity \\ true, on_fire \\ nil)

  defp metadata(
         id,
         %ItemStack{components: components, removed: %MapSet{}} = stack,
         no_gravity,
         on_fire
       )
       when is_map(components) do
    if stack.item_id == ItemTypes.id("air") do
      {:error, :empty_item}
    else
      fields = flags(on_fire) ++ [no_gravity: no_gravity, item_stack: stack]
      {:ok, binary_packet(EntityPackets.metadata(id, fields))}
    end
  rescue
    ArgumentError -> {:error, :invalid_item}
  end

  defp metadata(_, nil, _, _), do: {:error, :empty_item}
  defp metadata(_, _, _, _), do: {:error, :invalid_item}

  defp orb_metadata(id, value, on_fire),
    do: binary_packet(EntityPackets.metadata(id, flags(on_fire) ++ [experience_value: value]))

  # The on-fire shared flag (VMC-034n4e): `nil` until an item or orb first
  # burns, so a fresh one's packets stay as vanilla's; after that its value,
  # so the client learns when it goes out.
  defp flags(nil), do: []
  defp flags(on_fire), do: [shared_flags: if(on_fire, do: 1, else: 0)]

  # A step's on-fire flag (`ItemStep`'s), or the entry's when it names none
  # (a push, a teleport).
  defp on_fire(step, entry) do
    case {Map.fetch(step, :on_fire), entry[:on_fire]} do
      {:error, kept} -> kept
      {{:ok, true}, _} -> true
      {{:ok, false}, nil} -> nil
      {{:ok, false}, _} -> false
    end
  end

  defp binary_packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  def valid_position?({x, y, z}),
    do: coordinate?(x, 29_999_984) and coordinate?(z, 29_999_984) and coordinate?(y, 1_000_000)

  def valid_position?(_), do: false

  defp coordinate?(value, bound), do: is_number(value) and abs(value) <= bound
end
