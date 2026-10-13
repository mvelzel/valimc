defmodule Valimc.World.Items do
  @moduledoc "Bounded ephemeral stationary scene items. Only the enclosing region mutates these."
  alias Valimc.Protocol.{EntityPackets, ItemStack, ItemTypes, Wire}
  defstruct epoch: nil, entries: %{}, views: %{}, bytes: 0
  @max_items 256
  @max_bytes 524_288

  def new, do: %__MODULE__{epoch: make_ref()}

  def create(state, key, stack, {x, y, z} = position) do
    cond do
      not valid_position?(position) -> {:error, :invalid_item_position}
      Valimc.World.region_key(Valimc.World.chunk_key(x, z)) != key -> {:error, :wrong_region}
      map_size(state.entries) >= @max_items -> {:error, :item_count_limit}
      true -> build_new(state, stack, {x, y, z})
    end
  end

  def create(_, _, _, _), do: {:error, :invalid_item_position}

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
      build_entity(state, stack, {x, y, z}, id)
    end
  end

  defp build_entity(state, stack, {x, y, z}, id) when id in 1..2_147_483_647 do
    entity = %{entity_id: id, uuid: :crypto.strong_rand_bytes(16), x: x, y: y, z: z}
    spawn = binary_packet(EntityPackets.spawn_item(entity))
    {:ok, metadata} = metadata(id, stack)
    bytes = state.bytes + packet_bytes(spawn) + packet_bytes(metadata)

    if bytes <= @max_bytes do
      view = %{
        entity_id: id,
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

  defp build_entity(_, _, _, _), do: {:error, :entity_id_exhausted}

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

  defp valid_position?({x, y, z}),
    do: coordinate?(x, 29_999_984) and coordinate?(z, 29_999_984) and coordinate?(y, 1_000_000)

  defp coordinate?(value, bound), do: is_number(value) and abs(value) <= bound
end
