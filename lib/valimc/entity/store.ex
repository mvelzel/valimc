defmodule Valimc.Entity.Store do
  @moduledoc """
  A region owner's entity store (VMC-077h): every entity it owns, by network
  id with a uuid index, each of a kind (`:item` and `:orb` now, mobs and
  projectiles later), with its published view and the handoff
  ledger (`Valimc.Entity.Handoffs`). Only the owner mutates it.

  An entity keeps its network id (`Valimc.Entity.Ids`) for the life of the
  VM: a record handed over between owners carries it. Its `hops` count the
  handoffs it has made, so a permit granted before it left and came back no
  longer matches. Records are persisted one by one (`RegionStorage`), so the
  store has no count or size cap.
  """
  alias Valimc.Data.Grid
  alias Valimc.Entity.ItemMotionState
  alias Valimc.Protocol.{EntityPackets, ItemStack, ItemTypes}
  alias Valimc.Entity.{Ids, View}

  # The handoff ledger: the last outgoing sequence, the one outgoing intent and
  # the receipts of incoming handoffs by source.
  @ledger %{sequence: 0, outgoing: nil, incoming: %{}}
  defstruct epoch: nil, entries: %{}, uuids: %{}, views: %{}, ledger: @ledger
  @max_steps 32

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

  @doc "Advance counters and identify expired/below-world items; removal waits for the owner's durable commit."
  def age(state, ticks \\ 1, minimum_y \\ Grid.min_y()) do
    Enum.reduce(state.entries, {state, []}, fn
      {id, %{kind: :orb} = entry}, {items, expired} ->
        # An orb's age is a counter (vanilla despawns it at 6000 ticks); its
        # handles and view stay.
        age = min(entry.age + ticks, 6000)
        items = %{items | entries: Map.put(items.entries, id, %{entry | age: age})}

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

  @doc "Every entity's persistent record, by uuid (network ids are the VM's, never stored)."
  def records(state),
    do: state.entries |> Enum.map(fn {_, entry} -> record(entry) end) |> Enum.sort_by(& &1.uuid)

  def record(%{kind: :orb, entity: entity} = entry) do
    record =
      entity
      |> Map.take([:uuid, :x, :y, :z])
      |> Map.merge(%{kind: :orb, value: entry.value, count: entry.count, age: entry.age})

    # An imported orb's saved motion, kept for export (orbs do not move yet).
    record = if entry.saved, do: Map.put(record, :saved, entry.saved), else: record
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
             {:ok, id} <- Ids.next(),
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
      is_integer(age) and age in -32_768..5_999 and saved?(Map.get(record, :saved))
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

  defp build_record(state, id, %{kind: :orb} = record) do
    %{uuid: uuid, x: x, y: y, z: z, value: value} = record
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z}
    hops = Map.get(record, :hops, 0)

    metadata =
      binary_packet(EntityPackets.metadata(id, no_gravity: true, experience_value: value))

    view =
      :orb
      |> View.new(Map.put(entity, :on_ground, false), metadata, state.epoch, hops)
      |> Map.merge(%{revision: 1, physical_revision: 1, value: value, count: record.count})
      # The XP pickup request's fence (VMC-077i's protocol); an orb entity needs none.
      |> Map.put(:consumed, 0)

    entry = %{
      kind: :orb,
      entity: entity,
      value: value,
      count: record.count,
      age: record.age,
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
        with {:ok, id} <- record_id(state, record), do: build_record(state, id, record)
    end
  end

  def create_record(_, _, _), do: {:error, :invalid_item}

  # The id a handed-over record carries, unless this store already uses it.
  defp record_id(state, %{entity_id: id}) when is_integer(id) do
    if Ids.valid?(id) and not Map.has_key?(state.entries, id),
      do: {:ok, id},
      else: Ids.next()
  end

  defp record_id(_state, _record), do: Ids.next()

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
         {:ok, metadata} <- metadata(id, stack, entry.no_gravity) do
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

  defp advance_one(state, key, %{id: id, revision: revision, position: {x, y, z}, motion: motion}) do
    with {:ok, entry} <- current_item(state, state.epoch, id, revision),
         true <- valid_position?({x, y, z}) and ItemMotionState.valid?(motion),
         true <- Grid.region_key(Grid.chunk_key(x, z)) == key do
      entity = Map.merge(entry.entity, %{x: x, y: y, z: z, velocity: motion.velocity})
      old = state.views[id]

      metadata =
        if motion.no_gravity == entry.no_gravity do
          old.metadata
        else
          {:ok, packet} = metadata(id, entry.stack, motion.no_gravity)
          packet
        end

      if entity == entry.entity and Map.get(entry, :motion) == motion do
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
          |> Map.put(:motion, motion)

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

  defp advance_one(_, _, _), do: {:error, :invalid_item_steps}

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

  defp merge_hints(stack, motion),
    do: %{
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

  def return_capacity?(_state), do: true

  @doc "Whether `uuid` is in the outgoing handoff, so it cannot arrive back yet."
  def reserved_uuid?(%{ledger: %{outgoing: %{records: records}}}, uuid),
    do: Enum.any?(records, &(&1.uuid == uuid))

  def reserved_uuid?(_, _), do: false

  defp valid_record_motion?(record) do
    case Map.fetch(record, :motion) do
      :error -> true
      {:ok, motion} -> ItemMotionState.valid?(motion)
    end
  end

  defp metadata(id, stack, no_gravity \\ true)

  defp metadata(id, %ItemStack{components: components, removed: %MapSet{}} = stack, no_gravity)
       when is_map(components) do
    if stack.item_id == ItemTypes.id("air") do
      {:error, :empty_item}
    else
      {:ok, binary_packet(EntityPackets.metadata(id, no_gravity: no_gravity, item_stack: stack))}
    end
  rescue
    ArgumentError -> {:error, :invalid_item}
  end

  defp metadata(_, nil, _), do: {:error, :empty_item}
  defp metadata(_, _, _), do: {:error, :invalid_item}
  defp binary_packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  def valid_position?({x, y, z}),
    do: coordinate?(x, 29_999_984) and coordinate?(z, 29_999_984) and coordinate?(y, 1_000_000)

  def valid_position?(_), do: false

  defp coordinate?(value, bound), do: is_number(value) and abs(value) <= bound
end
