defmodule Valimc.World.Blocks do
  @moduledoc """
  Paletted section storage for one region, held in a Rust resource.

  The handle is mutable and owned by the region process: only that process may
  read or change it, and it must not be sent to other processes. Readers elsewhere
  receive values (block maps, encoded binaries) instead.

  Positions outside the region or the world height read as the flat base profile,
  matching the edit-map semantics this replaces; VMC-065 makes them explicit errors.
  """
  alias Valimc.Native
  alias Valimc.Physics.{FluidBlocks, HeightmapBlocks}
  alias Valimc.Protocol.Data
  alias Valimc.World.Chunk
  import Bitwise

  @enforce_keys [:ref, :key]
  defstruct [:ref, :key]

  @air_states [0, 18_649, 18_650]
  @air 1 <<< 6
  @fluid 1 <<< 7
  # Upper bound on one region's section memory (64 chunks of fully dense sections
  # need about 12.6 MiB).
  @budget 64 * 1024 * 1024

  @doc "Install the per-state flag table in the NIF; call once at application start."
  def init! do
    :ok =
      case Native.flags_init(flags()) do
        {:ok, :ok} -> :ok
        other -> raise "block flag initialization failed: #{inspect(other)}"
      end
  end

  @doc "One byte per state: heightmap predicate bits 0..5, air bit 6, fluid bit 7."
  def flags do
    for id <- 0..(Data.block_state_count() - 1), into: <<>> do
      {:ok, mask} = HeightmapBlocks.mask(id)
      {:ok, %{kind: fluid}} = FluidBlocks.fetch(id)
      air = if id in @air_states, do: @air, else: 0
      wet = if fluid == :empty, do: 0, else: @fluid
      <<mask ||| air ||| wet>>
    end
  end

  @doc "Storage for region `key`, starting from flat terrain plus sparse `edits`."
  def new({rx, rz} = key, edits \\ %{}) do
    size = Valimc.config(:region_size)
    layers = for y <- Chunk.min_y()..319, into: <<>>, do: <<Chunk.base(y)::16>>
    {:ok, ref} = Native.region_new(rx * size, rz * size, size, layers, @budget)
    blocks = %__MODULE__{ref: ref, key: key}

    case put(blocks, edits) do
      :ok -> {:ok, blocks}
      error -> error
    end
  end

  def get(%__MODULE__{} = blocks, {_, y, _} = position) do
    case Native.get_blocks(blocks.ref, [position]) do
      {:ok, [block]} -> block
      {:error, _} -> Chunk.base(y)
    end
  end

  @doc "A `position => block` map; out-of-region positions read the base profile."
  def get_many(%__MODULE__{} = blocks, positions) do
    positions = Enum.uniq(positions)

    case Native.get_blocks(blocks.ref, positions) do
      {:ok, states} ->
        Map.new(Enum.zip(positions, states))

      {:error, _} ->
        Map.new(positions, &{&1, get(blocks, &1)})
    end
  end

  @doc "Apply a `position => block` map atomically (all or nothing)."
  def put(%__MODULE__{}, changes) when map_size(changes) == 0, do: :ok

  def put(%__MODULE__{} = blocks, changes) when is_map(changes) do
    changes = for {{x, y, z}, block} <- changes, do: {x, y, z, block}

    case Native.set_blocks(blocks.ref, changes) do
      {:ok, _previous} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The sparse difference from flat terrain (the current persistence image)."
  def image(%__MODULE__{} = blocks) do
    {:ok, entries} = Native.diff(blocks.ref)
    Map.new(entries, fn {x, y, z, block} -> {{x, y, z}, block} end)
  end

  @doc "The persistence image after applying `changes`, without mutating storage."
  def image(%__MODULE__{} = blocks, changes) do
    Enum.reduce(changes, image(blocks), fn {{_, y, _} = position, block}, acc ->
      if block == Chunk.base(y),
        do: Map.delete(acc, position),
        else: Map.put(acc, position, block)
    end)
  end

  @doc """
  Section data and heightmaps for a chunk packet, or `:flat` for an untouched
  chunk (callers use the cached flat packet). The owner hands the result to a worker.
  """
  def encode(%__MODULE__{} = blocks, {cx, cz} = chunk) do
    biome = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")

    case Native.encode_chunk(blocks.ref, cx, cz, biome, Data.global_block_bits()) do
      {:ok, :flat} ->
        :flat

      {:ok, {sections, surface, motion}} ->
        %{chunk: chunk, sections: sections, surface: surface, motion: motion}
    end
  end

  @doc "A chunk's block-entity carriers (single chests) as `position => block`."
  def chunk_entities(%__MODULE__{} = blocks, {cx, cz}) do
    states = Valimc.ChestAccess.single_states() |> MapSet.to_list()
    {:ok, entries} = Native.chunk_find(blocks.ref, cx, cz, states)
    Map.new(entries, fn {x, y, z, block} -> {{x, y, z}, block} end)
  end

  @doc "A complete chunk packet (the reference shape of `Chunk.encode/2`)."
  def packet(%__MODULE__{} = blocks, chunk) do
    case encode(blocks, chunk) do
      :flat -> Chunk.encode(chunk, %{})
      encoded -> Chunk.packet(encoded, chunk_entities(blocks, chunk))
    end
  end

  @doc "An immutable read snapshot of one chunk (see `BlockSnapshot`), or nil if untouched."
  def snapshot(%__MODULE__{} = blocks, {cx, cz}) do
    {:ok, sections} = Native.snapshot_chunk(blocks.ref, cx, cz)
    sections
  end

  def touched_chunks(%__MODULE__{} = blocks) do
    {:ok, chunks} = Native.touched_chunks(blocks.ref)
    chunks
  end

  def heap_bytes(%__MODULE__{} = blocks) do
    {:ok, bytes} = Native.heap_bytes(blocks.ref)
    bytes
  end

  @doc "Release columns that returned to flat terrain."
  def compact(%__MODULE__{} = blocks) do
    {:ok, :ok} = Native.compact(blocks.ref)
    :ok
  end
end
