defmodule Valimc.World.Items do
  @moduledoc "Bounded scene items and accepted steps. Only the enclosing region mutates these."
  alias Valimc.ItemMotionState
  alias Valimc.Protocol.{EntityPackets, ItemStack, ItemTypes, Wire}
  alias Valimc.World.ItemLedger
  defstruct epoch: nil, entries: %{}, views: %{}, bytes: 0, ledger: %ItemLedger{}
  @max_items 256
  @max_bytes 524_288
  @max_steps 32

  def new, do: %__MODULE__{epoch: make_ref()}

  def snapshot(state), do: %{records: records(state), ledger: state.ledger}

  @doc "Advance owner counters without geometry, packet encoding or changing physical view versions."
  def age(state) do
    Enum.reduce(state.entries, {state, []}, fn {id, entry}, {items, expired} ->
      motion = Map.get(entry, :motion, %ItemMotionState{no_gravity: entry.no_gravity})
      next = ItemMotionState.tick(motion)

      items =
        if Map.get(entry, :motion) == next do
          items
        else
          revision = entry.revision + 1
          entry = entry |> Map.put(:motion, next) |> Map.put(:revision, revision)

          %{
            items
            | entries: Map.put(items.entries, id, entry),
              views: Map.update!(items.views, id, &%{&1 | revision: revision})
          }
        end

      expired =
        if next.age >= 6000,
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
      map_size(state.entries) >= @max_items -> {:error, :item_count_limit}
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

      state.ledger.outgoing != nil and Map.has_key?(state.ledger.outgoing.generations, uuid) ->
        {:error, :item_handoff_busy}

      map_size(state.entries) >= @max_items ->
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
        view = %{
          state.views[id]
          | revision: revision + 1,
            metadata: metadata,
            metadata_revision: state.views[id].metadata_revision + 1
        }

        bytes = state.bytes - packet_bytes(state.views[id].metadata) + packet_bytes(metadata)

        if bytes <= @max_bytes do
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
        {:error, :stale_region}

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
        view = %{
          old
          | revision: revision + 1,
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

        if bytes <= @max_bytes do
          entry =
            %{
              entry
              | entity: entity,
                revision: revision + 1,
                no_gravity: motion.no_gravity,
                physical_revision:
                  entry.physical_revision +
                    if(
                      entity != entry.entity or motion.no_gravity != entry.no_gravity or
                        motion.on_ground !=
                          Map.get(Map.get(entry, :motion, %{}), :on_ground, false),
                      do: 1,
                      else: 0
                    )
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

  def packet_bytes({id, payload}), do: byte_size(Wire.varint(id)) + byte_size(payload)

  defp current(state, epoch, id, revision) do
    cond do
      epoch != state.epoch -> {:error, :stale_region}
      not Map.has_key?(state.entries, id) -> {:error, :missing_item}
      state.entries[id].revision != revision -> {:error, :stale_item}
      true -> {:ok, state.entries[id]}
    end
  end

  defp build_new(state, stack, {x, y, z}) do
    # Validate before allocating IDs/entropy. IDs share the VM-wide source used by players.
    with {:ok, _} <- metadata(1, stack) do
      id = System.unique_integer([:positive])
      build_entity(state, stack, {x, y, z}, id, :crypto.strong_rand_bytes(16))
    end
  end

  defp build_entity(state, stack, position, id, uuid, motion \\ nil)

  defp build_entity(state, stack, {x, y, z}, id, uuid, motion) when id in 1..2_147_483_647 do
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z}
    entity = if motion, do: Map.put(entity, :velocity, motion.velocity), else: entity
    no_gravity = if motion, do: motion.no_gravity, else: true
    on_ground = if motion, do: motion.on_ground, else: false
    spawn = binary_packet(EntityPackets.spawn_item(entity))
    {:ok, metadata} = metadata(id, stack, no_gravity)
    position = binary_packet(EntityPackets.position(Map.put(entity, :on_ground, on_ground)))

    velocity =
      binary_packet(EntityPackets.motion(id, Map.get(entity, :velocity, {0.0, 0.0, 0.0})))

    bytes =
      state.bytes + Enum.sum(Enum.map([spawn, metadata, position, velocity], &packet_bytes/1))

    if bytes <= @max_bytes do
      view = %{
        entity_id: id,
        uuid: uuid,
        ownership_generation: Map.get(state.ledger.generations, uuid, 0),
        epoch: state.epoch,
        revision: 1,
        metadata_revision: 1,
        motion_revision: 1,
        chunk: Valimc.World.chunk_key(x, z),
        spawn: spawn,
        metadata: metadata,
        position: position,
        motion: velocity
      }

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
