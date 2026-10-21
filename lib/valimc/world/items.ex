defmodule Valimc.World.Items do
  @moduledoc "Bounded scene items and accepted steps. Only the enclosing region mutates these."
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.{EntityPackets, ItemStack, ItemTypes}
  alias Valimc.World.{EntityView, ItemLedger}
  defstruct epoch: nil, entries: %{}, views: %{}, bytes: 0, ledger: %ItemLedger{}
  @max_items 256
  @max_bytes 524_288
  @max_steps 32

  def new, do: %__MODULE__{epoch: make_ref()}

  @doc "Rebase worker-created items onto current motion/counters; never replace existing items or receipts."
  def merge_created(%{epoch: epoch} = current, %{epoch: epoch} = original, original),
    do: {:ok, current}

  def merge_created(current, original, proposed) do
    original_ids = Map.keys(original.entries)
    added = Map.drop(proposed.entries, original_ids)
    added_bytes = proposed.bytes - original.bytes

    cond do
      current.epoch != original.epoch or proposed.epoch != original.epoch or
        proposed.ledger != original.ledger or
        Map.take(proposed.entries, original_ids) != original.entries or added_bytes < 0 ->
        {:error, :invalid_item_additions}

      map_size(current.entries) + map_size(added) + return_slots(current) > @max_items ->
        {:error, :item_count_limit}

      current.bytes + added_bytes > @max_bytes ->
        {:error, :item_bytes_limit}

      Enum.any?(added, fn {id, entry} ->
        Map.has_key?(current.entries, id) or reserved_uuid?(current, entry.entity.uuid) or
            match?({:ok, _}, find(current, entry.entity.uuid))
      end) ->
        {:error, :duplicate_item_uuid}

      true ->
        {:ok,
         %{
           current
           | entries: Map.merge(current.entries, added),
             views: Map.merge(current.views, Map.take(proposed.views, Map.keys(added))),
             bytes: current.bytes + added_bytes
         }}
    end
  end

  def snapshot(state), do: %{records: records(state), ledger: state.ledger}

  @doc "Advance counters and identify expired/below-world items; removal waits for the owner's durable commit."
  def age(state, ticks \\ 1, minimum_y \\ Valimc.World.Chunk.min_y()) do
    Enum.reduce(state.entries, {state, []}, fn {id, entry}, {items, expired} ->
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

  def records(state) do
    state.entries
    |> Enum.map(fn {_, %{entity: entity, stack: stack} = entry} ->
      record = entity |> Map.take([:uuid, :x, :y, :z]) |> Map.put(:stack, stack)
      if Map.has_key?(entry, :motion), do: Map.put(record, :motion, entry.motion), else: record
    end)
    |> Enum.sort_by(& &1.uuid)
  end

  def restore(key, records, ledger \\ %ItemLedger{})

  def restore(key, records, %ItemLedger{} = ledger) when is_list(records) do
    prefix = Enum.take(records, @max_items + 1)

    if length(prefix) > @max_items or
         not match?({:ok, _}, ItemLedger.encode(key, prefix, %{}, ledger)) do
      {:error, :invalid_item_file}
    else
      Enum.reduce_while(prefix, {:ok, %{new() | ledger: ledger}, MapSet.new()}, fn
        %{uuid: uuid, x: x, y: y, z: z, stack: stack} = record, {:ok, state, seen} ->
          with true <-
                 is_binary(uuid) and byte_size(uuid) == 16 and not MapSet.member?(seen, uuid),
               true <- valid_position?({x, y, z}),
               true <- valid_record_motion?(record),
               true <- Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key,
               {:ok, _} <- metadata(1, stack),
               {:ok, next, _} <-
                 build_entity(
                   state,
                   stack,
                   {x, y, z},
                   System.unique_integer([:positive]),
                   uuid,
                   Map.get(record, :motion)
                 ) do
            {:cont, {:ok, next, MapSet.put(seen, uuid)}}
          else
            _ -> {:halt, {:error, :invalid_item_file}}
          end

        _, _ ->
          {:halt, {:error, :invalid_item_file}}
      end)
      |> case do
        {:ok, state, _} -> {:ok, state}
        error -> error
      end
    end
  rescue
    _ -> {:error, :invalid_item_file}
  end

  def restore(_, _, _), do: {:error, :invalid_item_file}

  def find(state, <<_::128>> = uuid) do
    case Enum.find(state.entries, fn {_, entry} -> entry.entity.uuid == uuid end) do
      {id, entry} -> {:ok, {state.epoch, id, entry.revision}}
      nil -> {:error, :missing_item}
    end
  end

  def find(_, _), do: {:error, :invalid_item_uuid}

  def create(state, key, stack, {x, y, z} = position) do
    cond do
      not valid_position?(position) -> {:error, :invalid_item_position}
      Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != key -> {:error, :wrong_region}
      map_size(state.entries) + return_slots(state) >= @max_items -> {:error, :item_count_limit}
      true -> build_new(state, stack, {x, y, z})
    end
  end

  def create(_, _, _, _), do: {:error, :invalid_item_position}

  @doc "Creates a stable-UUID inbox record; the caller commits its receipt atomically."
  def create_record(
        state,
        key,
        %{uuid: <<_::128>> = uuid, x: x, y: y, z: z, stack: stack} = record
      ) do
    cond do
      not valid_position?({x, y, z}) ->
        {:error, :invalid_item_position}

      not valid_record_motion?(record) ->
        {:error, :invalid_item}

      Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != key ->
        {:error, :wrong_region}

      match?({:ok, _}, find(state, uuid)) ->
        {:error, :duplicate_item_uuid}

      reserved_uuid?(state, uuid) ->
        {:error, :item_handoff_busy}

      map_size(state.entries) + return_slots(state) >= @max_items ->
        {:error, :item_count_limit}

      true ->
        with {:ok, _} <- metadata(1, stack),
             do:
               build_entity(
                 state,
                 stack,
                 {x, y, z},
                 System.unique_integer([:positive]),
                 uuid,
                 Map.get(record, :motion)
               )
    end
  end

  def create_record(_, _, _), do: {:error, :invalid_item}

  def replace(state, epoch, id, revision, stack) do
    with {:ok, entry} <- current(state, epoch, id, revision),
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

        bytes = state.bytes - packet_bytes(state.views[id].metadata) + packet_bytes(metadata)

        if bytes + return_bytes(state) <= @max_bytes do
          entry = %{
            entry
            | stack: stack,
              revision: revision + 1,
              physical_revision: entry.physical_revision + 1
          }

          next = %{
            state
            | entries: Map.put(state.entries, id, entry),
              views: Map.put(state.views, id, view),
              bytes: bytes
          }

          {:ok, next, {epoch, id, revision + 1}}
        else
          {:error, :item_byte_limit}
        end
      end
    end
  end

  def remove(state, epoch, id, revision) do
    with {:ok, entry} <- current(state, epoch, id, revision) do
      view = state.views[id]

      {:ok,
       %{
         state
         | entries: Map.delete(state.entries, id),
           views: Map.delete(state.views, id),
           bytes: state.bytes - view_bytes(view),
           ledger: %{
             state.ledger
             | generations: Map.delete(state.ledger.generations, entry.entity.uuid)
           }
       }}
    end
  end

  @doc "Atomic bounded steps from a trusted owner; geometry/clock admission belongs to the caller."
  def advance(state, key, epoch, steps) when is_list(steps) do
    steps = Enum.take(steps, @max_steps + 1)

    cond do
      epoch != state.epoch ->
        Valimc.Error.retry(:stale_owner)

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
    with {:ok, entry} <- current(state, state.epoch, id, revision),
         true <- valid_position?({x, y, z}) and ItemMotionState.valid?(motion),
         true <- Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key do
      entity = Map.merge(entry.entity, %{x: x, y: y, z: z, velocity: motion.velocity})

      position =
        binary_packet(EntityPackets.position(Map.put(entity, :on_ground, motion.on_ground)))

      velocity = binary_packet(EntityPackets.motion(id, motion.velocity))
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
            chunk: Valimc.World.chunk_key(x, z),
            spawn: binary_packet(EntityPackets.spawn_item(entity)),
            position: position,
            motion: velocity,
            metadata: metadata,
            metadata_revision:
              old.metadata_revision + if(metadata == old.metadata, do: 0, else: 1),
            motion_revision:
              old.motion_revision +
                if(position == old.position and velocity == old.motion, do: 0, else: 1)
        }

        bytes = state.bytes - view_bytes(old) + view_bytes(view)

        if bytes + return_bytes(state) <= @max_bytes do
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
               views: Map.put(state.views, id, view),
               bytes: bytes
           }, {state.epoch, id, revision + 1}}
        else
          {:error, :item_byte_limit}
        end
      end
    else
      false -> {:error, :invalid_item_step}
      error -> error
    end
  end

  defp advance_one(_, _, _), do: {:error, :invalid_item_steps}

  defp view_bytes(view),
    do:
      Enum.sum(Enum.map([view.spawn, view.metadata, view.position, view.motion], &packet_bytes/1))

  defdelegate packet_bytes(packet), to: EntityView

  defp current(state, epoch, id, revision) do
    cond do
      epoch != state.epoch -> Valimc.Error.retry(:stale_owner)
      not Map.has_key?(state.entries, id) -> {:error, :missing_item}
      state.entries[id].revision != revision -> {:error, :stale_item}
      true -> {:ok, state.entries[id]}
    end
  end

  defp build_new(state, stack, {x, y, z}) do
    # Validate before allocating IDs/entropy. IDs share the VM-wide source used by players.
    with {:ok, _} <- metadata(1, stack),
         {:ok, id} <- EntityView.id() do
      build_entity(state, stack, {x, y, z}, id, :crypto.strong_rand_bytes(16))
    end
  end

  defp build_entity(state, stack, position, id, uuid, motion \\ nil)

  defp build_entity(state, stack, {x, y, z}, id, uuid, motion)
       when id in 1..2_147_483_647 do
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z}
    entity = if motion, do: Map.put(entity, :velocity, motion.velocity), else: entity
    no_gravity = if motion, do: motion.no_gravity, else: true
    on_ground = if motion, do: motion.on_ground, else: false
    {:ok, metadata} = metadata(id, stack, no_gravity)

    base =
      EntityView.new(
        :item,
        Map.put(entity, :on_ground, on_ground),
        metadata,
        state.epoch,
        Map.get(state.ledger.generations, uuid, 0)
      )

    bytes = state.bytes + EntityView.bytes(base)

    if bytes + return_bytes(state) <= @max_bytes do
      view =
        base
        |> Map.merge(%{
          revision: 1,
          physical_revision: 1,
          pickup_delay: if(motion, do: motion.pickup_delay, else: 0)
        })
        |> Map.merge(merge_hints(stack, motion || %ItemMotionState{no_gravity: no_gravity}))

      entry = %{
        entity: entity,
        stack: stack,
        revision: 1,
        physical_revision: 1,
        no_gravity: no_gravity
      }

      entry = if motion, do: Map.put(entry, :motion, motion), else: entry

      next = %{
        state
        | entries: Map.put(state.entries, id, entry),
          views: Map.put(state.views, id, view),
          bytes: bytes
      }

      {:ok, next, {state.epoch, id, 1}}
    else
      {:error, :item_byte_limit}
    end
  end

  defp build_entity(_, _, _, _, _, _), do: {:error, :entity_id_exhausted}

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

  def return_capacity?(state),
    do:
      map_size(state.entries) + return_slots(state) <= @max_items and
        state.bytes + return_bytes(state) <= @max_bytes

  def reserved_uuid?(%{ledger: %{outgoing: %{kind: :merge, request: request}}}, uuid),
    do: request.donor.uuid == uuid

  def reserved_uuid?(%{ledger: %{outgoing: %{generations: generations}}}, uuid),
    do: Map.has_key?(generations, uuid)

  def reserved_uuid?(_, _), do: false

  defp return_slots(%{ledger: %{outgoing: %{kind: :merge}}}), do: 1
  defp return_slots(_), do: 0
  defp return_bytes(%{ledger: %{outgoing: %{kind: :merge, return_bytes: bytes}}}), do: bytes
  defp return_bytes(_), do: 0

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
