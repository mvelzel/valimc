defmodule Valimc.World.Items do
  @moduledoc "Bounded stationary scene items. Only the enclosing region mutates these."
  alias Valimc.Protocol.{EntityPackets, ItemStack, ItemTypes, Wire}
  defstruct epoch: nil, entries: %{}, views: %{}, bytes: 0
  @max_items 256
  @max_bytes 524_288

  def new, do: %__MODULE__{epoch: make_ref()}

  def records(state) do
    state.entries
    |> Enum.map(fn {_, %{entity: entity, stack: stack}} ->
      entity |> Map.take([:uuid, :x, :y, :z]) |> Map.put(:stack, stack)
    end)
    |> Enum.sort_by(& &1.uuid)
  end

  def restore(key, records) when is_list(records) do
    prefix = Enum.take(records, @max_items + 1)

    if length(prefix) > @max_items do
      {:error, :invalid_item_file}
    else
      Enum.reduce_while(prefix, {:ok, new(), MapSet.new()}, fn
        %{uuid: uuid, x: x, y: y, z: z, stack: stack}, {:ok, state, seen} ->
          with true <-
                 is_binary(uuid) and byte_size(uuid) == 16 and not MapSet.member?(seen, uuid),
               true <- valid_position?({x, y, z}),
               true <- Valimc.World.region_key(Valimc.World.chunk_key(x, z)) == key,
               {:ok, _} <- metadata(1, stack),
               {:ok, next, _} <-
                 build_entity(state, stack, {x, y, z}, System.unique_integer([:positive]), uuid) do
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

  def restore(_, _), do: {:error, :invalid_item_file}

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
  def create_record(state, key, %{uuid: <<_::128>> = uuid, x: x, y: y, z: z, stack: stack}) do
    cond do
      not valid_position?({x, y, z}) ->
        {:error, :invalid_item_position}

      Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != key ->
        {:error, :wrong_region}

      match?({:ok, _}, find(state, uuid)) ->
        {:error, :duplicate_item_uuid}

      map_size(state.entries) >= @max_items ->
        {:error, :item_count_limit}

      true ->
        with {:ok, _} <- metadata(1, stack),
             do: build_entity(state, stack, {x, y, z}, System.unique_integer([:positive]), uuid)
    end
  end

  def create_record(_, _, _), do: {:error, :invalid_item}

  def replace(state, epoch, id, revision, stack) do
    with {:ok, entry} <- current(state, epoch, id, revision),
         {:ok, metadata} <- metadata(id, stack) do
      if stack == entry.stack do
        {:ok, state, {epoch, id, revision}}
      else
        view = %{state.views[id] | revision: revision + 1, metadata: metadata}
        bytes = state.bytes - packet_bytes(state.views[id].metadata) + packet_bytes(metadata)

        if bytes <= @max_bytes do
          entry = %{entry | stack: stack, revision: revision + 1}

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
    with {:ok, _entry} <- current(state, epoch, id, revision) do
      view = state.views[id]

      {:ok,
       %{
         state
         | entries: Map.delete(state.entries, id),
           views: Map.delete(state.views, id),
           bytes: state.bytes - packet_bytes(view.spawn) - packet_bytes(view.metadata)
       }}
    end
  end

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

  defp build_entity(state, stack, {x, y, z}, id, uuid) when id in 1..2_147_483_647 do
    entity = %{entity_id: id, uuid: uuid, x: x, y: y, z: z}
    spawn = binary_packet(EntityPackets.spawn_item(entity))
    {:ok, metadata} = metadata(id, stack)
    bytes = state.bytes + packet_bytes(spawn) + packet_bytes(metadata)

    if bytes <= @max_bytes do
      view = %{
        entity_id: id,
        uuid: uuid,
        epoch: state.epoch,
        revision: 1,
        chunk: Valimc.World.chunk_key(x, z),
        spawn: spawn,
        metadata: metadata
      }

      entry = %{entity: entity, stack: stack, revision: 1}

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

  defp build_entity(_, _, _, _, _), do: {:error, :entity_id_exhausted}

  defp metadata(id, %ItemStack{components: components, removed: %MapSet{}} = stack)
       when is_map(components) do
    if stack.item_id == ItemTypes.id("air") do
      {:error, :empty_item}
    else
      {:ok, binary_packet(EntityPackets.metadata(id, no_gravity: true, item_stack: stack))}
    end
  rescue
    ArgumentError -> {:error, :invalid_item}
  end

  defp metadata(_, nil), do: {:error, :empty_item}
  defp metadata(_, _), do: {:error, :invalid_item}
  defp binary_packet({id, payload}), do: {id, IO.iodata_to_binary(payload)}

  def valid_position?({x, y, z}),
    do: coordinate?(x, 29_999_984) and coordinate?(z, 29_999_984) and coordinate?(y, 1_000_000)

  def valid_position?(_), do: false

  defp coordinate?(value, bound), do: is_number(value) and abs(value) <= bound
end
