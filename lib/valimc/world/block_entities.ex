defmodule Valimc.World.BlockEntities do
  @moduledoc """
  Preserved vanilla block entities of one region (VMC-021e1): imported compounds
  of kinds ValiMC does not own yet (signs, banners, beds, skulls, double chests,
  locked containers...). The region owner holds them so chunk packets carry
  vanilla's update tag, so their blocks refuse changes that would lose the data,
  and so export writes them back.

  An entry is live only while the block at its position still creates its type;
  readers check that (`live/3`) instead of the owner rewriting the set on every
  block change. The set grows only by import and generation, which persist it
  whole; an unpacked loot chest (VMC-072b) leaves it by a dropped position.
  """
  alias Valimc.Anvil.BlockEntity
  alias Valimc.NBT
  alias Valimc.Physics.BlockEntities, as: Types

  @max_entries 32_768
  @max_bytes 32 * 1024 * 1024
  # A larger update tag is sent empty rather than refused (the block still renders).
  @max_update 262_144
  @update_limits %{NBT.disk_limits() | bytes: @max_update, duplicates: :refuse}
  # Kinds whose removal vanilla drops nothing for and whose data ValiMC writes
  # itself (an end gateway's exit, VMC-026b4): their blocks change freely.
  @replaceable ["minecraft:end_gateway"]

  defstruct entries: %{}

  def max_entries, do: @max_entries

  @doc "Build from `position => {type_id, nbt}` (disk-encoded compounds); validates every entry."
  def new(stored) when is_map(stored) and map_size(stored) <= @max_entries do
    Enum.reduce_while(stored, {:ok, %__MODULE__{}, 0}, fn
      {{x, y, z} = position, {type, nbt}}, {:ok, acc, bytes}
      when is_integer(x) and is_integer(y) and is_integer(z) and is_integer(type) and
             is_binary(nbt) ->
        with name when is_binary(name) <- Types.type_name(type),
             {:ok, {:compound, _} = tag} <- NBT.read(nbt) do
          entry = %{
            type: type,
            nbt: nbt,
            update: update(name, tag),
            data: name not in @replaceable and BlockEntity.holds_data?(tag)
          }

          bytes = bytes + byte_size(nbt)

          if bytes <= @max_bytes,
            do: {:cont, {:ok, %{acc | entries: Map.put(acc.entries, position, entry)}, bytes}},
            else: {:halt, {:error, :block_entity_bytes}}
        else
          _ -> {:halt, {:error, {:invalid_block_entity, position}}}
        end

      _, _ ->
        {:halt, {:error, :invalid_block_entities}}
    end)
    |> case do
      {:ok, entities, _} -> {:ok, entities}
      error -> error
    end
  end

  def new(_), do: {:error, :invalid_block_entities}

  @doc "The persisted form: `position => {type_id, nbt}`."
  def stored(%__MODULE__{entries: entries}),
    do: Map.new(entries, fn {position, entry} -> {position, {entry.type, entry.nbt}} end)

  @doc "Encode a compound for storage, refusing one over the region budget."
  def encode_nbt({:compound, _} = tag) do
    nbt = IO.iodata_to_binary(NBT.write(tag))
    if byte_size(nbt) <= @max_bytes, do: {:ok, nbt}, else: {:error, :block_entity_bytes}
  rescue
    _ -> {:error, :invalid_block_entity}
  end

  # Vanilla sends an empty update tag as no tag at all.
  defp update(name, tag) do
    case BlockEntity.update_tag(name, tag) do
      {:compound, fields} when map_size(fields) == 0 -> nil
      update -> IO.iodata_to_binary(NBT.encode(update, @update_limits))
    end
  rescue
    _ -> nil
  catch
    _, _ -> nil
  end

  @doc "The live entry at `position` given the block there, or nil."
  def live(%__MODULE__{entries: entries}, position, block) do
    case entries do
      %{^position => %{type: type} = entry} ->
        if Types.type_id(block) == type, do: entry

      _ ->
        nil
    end
  end

  @doc """
  The set with `entries` (`position => {type_id, nbt}`) added or replaced,
  each of the type the block at its position (`current`) creates, and the
  whole set as the store keeps it: `{:ok, entities, stored}` or an error.
  """
  def put(%__MODULE__{entries: entries} = entities, new, current) when is_map(new) do
    with true <-
           Enum.all?(new, fn {position, {type, _}} ->
             Types.type_id(current.(position)) == type
           end),
         {:ok, %__MODULE__{entries: added}} <- new(new),
         merged = Map.merge(entries, added),
         true <- map_size(merged) <= @max_entries do
      {:ok, %{entities | entries: merged},
       Map.new(merged, fn {position, e} -> {position, {e.type, e.nbt}} end)}
    else
      false -> {:error, :invalid_block_entity}
      error -> error
    end
  end

  @doc "The set without the entry at `position`."
  def drop(%__MODULE__{entries: entries} = entities, position),
    do: %{entities | entries: Map.delete(entries, position)}

  @doc "Positions of entries in chunk `{cx, cz}`."
  def in_chunk(%__MODULE__{entries: entries}, {cx, cz}) do
    for {{x, _, z} = position, _} <- entries,
        Integer.floor_div(x, 16) == cx and Integer.floor_div(z, 16) == cz,
        do: position
  end

  @doc """
  Chunk packet entries `{position, type_id, update}` for the live entries of a
  chunk; `blocks` maps their positions to current states.
  """
  def chunk_entries(%__MODULE__{} = entities, chunk, blocks) do
    for position <- in_chunk(entities, chunk),
        entry = live(entities, position, Map.fetch!(blocks, position)),
        entry != nil,
        do: {position, entry.type, entry.update}
  end

  @doc """
  Whether `changes` (`position => block`) would replace a live preserved block
  entity that holds data by a block of another type (vanilla would drop or spill
  what ValiMC cannot). A change within the type (waterlogging, facing) keeps it.
  """
  def protected?(%__MODULE__{entries: entries} = entities, changes, current) do
    map_size(entries) > 0 and
      Enum.any?(changes, fn {position, block} ->
        case entries do
          %{^position => _} ->
            previous = current.(position)
            entry = live(entities, position, previous)
            entry != nil and entry.data and Types.type_id(block) != entry.type

          _ ->
            false
        end
      end)
  end
end
