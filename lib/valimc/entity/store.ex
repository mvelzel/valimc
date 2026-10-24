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
  """
  alias Valimc.Data.Grid
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.{EntityPackets, ItemData, ItemStack, ItemTypes}
  alias Valimc.Entity.{Body, ExperienceOrbs, Ids, View}

  # The handoff ledger: the last outgoing sequence, the one outgoing intent and
  # the receipts of incoming handoffs by source.
  @ledger %{sequence: 0, outgoing: nil, incoming: %{}}
  # `deaths`: bodies whose mob died with drops its owner has not dropped yet
  # (`take_deaths/1`, VMC-037n).
  defstruct epoch: nil, entries: %{}, uuids: %{}, views: %{}, ledger: @ledger, deaths: []
  @max_steps 32
  @bodies [:mob, :object]
  # The entity events a view keeps for its tracker (each tick sends the new
  # ones): a hurt squid's ink is 30 particles beside its sounds (VMC-043e).
  @kept_events 40

  def empty_ledger, do: @ledger

  def new, do: %__MODULE__{epoch: make_ref()}

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
             uuids: Enum.into(added, current.uuids, fn {id, e} -> {e.entity.uuid, id} end),
             views: Map.merge(current.views, Map.take(proposed.views, Map.keys(added)))
         }}
    end
  end

  @doc """
  Advance counters and identify expired/below-world items and the orbs merged
  away (`merge_orbs/2`); removal waits for the owner's durable commit.
  """
  def age(state, ticks \\ 1, minimum_y \\ Grid.min_y(), game_tick \\ nil) do
    {state, absorbed} = merge_orbs(state, ticks)

    {state, expired} = age_entries(state, ticks, minimum_y, game_tick)
    {state, Enum.uniq(absorbed ++ expired)}
  end

  # Orbs merge when they scan (VMC-034n4c): on their first tick and every
  # twentieth after (`ExperienceOrb.tick` at `tickCount % 20 == 1`), in id
  # order; `lived` counts an orb's ticks in this VM, as vanilla's `tickCount`.
  defp merge_orbs(state, ticks) do
    orbs = for {id, %{kind: :orb} = entry} <- state.entries, do: {id, entry}

    scanning =
      for {id, %{lived: lived}} <- orbs,
          lived + 1 + Integer.mod(-lived, 20) <= lived + ticks,
          do: id

    if scanning == [] do
      {state, []}
    else
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
                views: Map.put(acc.views, id, view)
            }
          end
        end)

      {state, for(id <- absorbed, do: {state.epoch, id, state.entries[id].revision})}
    end
  end

  defp age_body(
         %Body{type: "minecraft:ender_dragon", data: %{aged_tick: tick}} = body,
         _ticks,
         tick
       )
       when tick != nil, do: {body, [], false}

  defp age_body(body, ticks, game_tick) do
    {body, events, done} =
      Enum.reduce_while(1..min(ticks, 40), {body, [], false}, fn _, {body, events, _} ->
        {body, more, done} = Body.tick(body)
        {if(done, do: :halt, else: :cont), {body, events ++ more, done}}
      end)

    body =
      if body.type == "minecraft:ender_dragon" and game_tick != nil,
        do: %{body | data: Map.put(body.data, :aged_tick, game_tick)},
        else: body

    {body, events, done}
  end

  defp age_entries(state, ticks, minimum_y, game_tick) do
    Enum.reduce(state.entries, {state, []}, fn
      {id, %{kind: kind} = entry}, {items, expired} when kind in @bodies ->
        # A dragon can move between sibling sections during this group tick.
        # Its living timers, like its actor, run only once on that tick.
        {body, events, done} = age_body(entry.body, ticks, game_tick)

        items =
          if body == entry.body and events == [],
            do: items,
            else: put_body(items, id, body, events)

        expired =
          if done or entry.entity.y < minimum_y - 64,
            do: [{items.epoch, id, items.entries[id].revision} | expired],
            else: expired

        {idle(items, id, kind, ticks), expired}

      {id, %{kind: :orb} = entry}, {items, expired} ->
        # An orb's age is a counter (vanilla despawns it at 6000 ticks); its
        # handles and view stay.
        age = min(entry.age + ticks, 6000)
        # Its portal cooldown runs down (VMC-026d).
        motion = %{entry.motion | portal_cooldown: max(0, entry.motion.portal_cooldown - ticks)}
        entry = %{entry | age: age, lived: entry.lived + ticks, motion: motion}
        items = %{items | entries: Map.put(items.entries, id, entry)}

        expired =
          if age >= 6000 or entry.entity.y < minimum_y - 64,
            do: [{items.epoch, id, entry.revision} | expired],
            else: expired

        {items, expired}

      {id, entry}, {items, expired} ->
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

  defp idle(items, _id, _kind, _ticks), do: items

  @doc "Restart the idle time of mobs `ids` (a player came within 32 blocks)."
  def reset_idle(state, ids) do
    entries =
      Enum.reduce(ids, state.entries, fn id, entries ->
        case entries do
          %{^id => %{kind: :mob} = entry} -> Map.put(entries, id, Map.put(entry, :idle, 0))
          _ -> entries
        end
      end)

    %{state | entries: entries}
  end

  @doc "Every entity's persistent record, by uuid (network ids are the VM's, never stored)."
  def records(state),
    do: state.entries |> Enum.map(fn {_, entry} -> record(entry) end) |> Enum.sort_by(& &1.uuid)

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
      with {:ok, entry} <- current(current, epoch, id, revision),
           {:ok, next} <- remove(current, epoch, id, revision) do
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

  def restore(key, records, ledger \\ @ledger)

  def restore(key, records, %{sequence: _, outgoing: _, incoming: _} = ledger)
      when is_list(records) do
    begin(fn ->
      Enum.reduce_while(records, {:ok, %{new() | ledger: ledger}}, fn record, {:ok, state} ->
        with true <- valid_record?(key, record) and not Map.has_key?(state.uuids, record.uuid),
             {:ok, id} <- next_id(record),
             {:ok, next, _} <- build_record(state, id, record) do
          {:cont, {:ok, next}}
        else
          _ -> {:halt, {:error, :invalid_item_file}}
        end
      end)
    end)
  end

  def restore(_, _, _), do: {:error, :invalid_item_file}

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

      {:ok,
       %{
         state
         | entries: Map.put(state.entries, id, entry),
           uuids: Map.put(state.uuids, uuid, id),
           views: Map.put(state.views, id, body_view(state.epoch, entry))
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
         uuids: Map.put(state.uuids, uuid, id),
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
  defp id_span(%{type: "minecraft:ender_dragon"}), do: 1 + length(Valimc.AI.Dragon.Facts.parts())
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
            views: Map.put(state.views, id, view)
        }

        {:ok, next, {epoch, id, revision + 1}}
      end
    end
  end

  def remove(state, epoch, id, revision) do
    with {:ok, entry} <- current(state, epoch, id, revision) do
      {:ok,
       %{
         state
         | entries: Map.delete(state.entries, id),
           uuids: Map.delete(state.uuids, entry.entity.uuid),
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
          %{body: %Body{} = body} -> body
          %{rotation: {yaw, pitch}} -> %{entry.body | yaw: yaw, pitch: pitch, head_yaw: yaw}
          _ -> entry.body
        end

      moved = {x, y, z} != {entry.entity.x, entry.entity.y, entry.entity.z}

      entry = %{
        entry
        | entity: %{entry.entity | x: x, y: y, z: z},
          physical_revision: entry.physical_revision + if(moved, do: 1, else: 0)
      }

      # A thinking mob's idle time is its AI's (`noActionTime`, VMC-041a).
      entry = if is_map_key(step, :idle), do: Map.put(entry, :idle, step.idle), else: entry
      state = %{state | entries: Map.put(state.entries, id, entry)}

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

  @doc "Entity `id`'s body changes to `body` with `events` (a hit, a push): the new state."
  def change_body(state, id, %Body{} = body, events \\ []) do
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
      %{kind: kind, body: body, revision: revision} when kind in @bodies ->
        case Body.kill(body) do
          :remove ->
            remove(state, state.epoch, id, revision)

          :ignored ->
            {:ok, state}

          # It dies as any death does: its owner drops what it leaves.
          {:dying, body, events} ->
            {:ok, change_body(state, id, Valimc.Entity.Combat.died(body, %{}), events)}
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

  defp put_entry(state, id, entry),
    do: %{
      state
      | entries: Map.put(state.entries, id, entry),
        views: Map.put(state.views, id, body_view(state.epoch, entry, state.views[id]))
    }

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
      true -> {:ok, state.entries[id]}
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
        uuids: Map.put(state.uuids, uuid, id),
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
