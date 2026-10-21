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
  alias Valimc.Protocol.Data
  alias Valimc.World.Chunk

  @enforce_keys [:ref, :key]
  defstruct [:ref, :key]

  # Upper bound on one region's section memory (64 chunks of fully dense sections
  # need about 12.6 MiB).
  @budget 64 * 1024 * 1024

  @doc """
  Storage for region `key`: flat terrain, then imported column `images`
  (`chunk => image`, VMC-021c), then sparse `edits` on top.
  """
  def new({rx, rz} = key, edits \\ %{}, images \\ %{}) do
    size = Valimc.config(:region_size)
    layers = for y <- Chunk.min_y()..319, into: <<>>, do: <<Chunk.base(y)::16>>
    {:ok, ref} = Native.region_new(rx * size, rz * size, size, layers, @budget)
    # The owner's dimension may have no sky light (the Nether, VMC-026b).
    unless Valimc.Dimension.facts().sky_light, do: :ok = Native.light_sky(ref, false)
    blocks = %__MODULE__{ref: ref, key: key}

    restored =
      Enum.reduce_while(images, :ok, fn {{cx, cz}, image}, :ok ->
        case Native.put_column_image(ref, cx, cz, image) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:invalid_column_image, {cx, cz}, reason}}}
        end
      end)

    with :ok <- restored, :ok <- put(blocks, edits), do: {:ok, blocks}
  end

  @doc "Light the region and its one-chunk ring from scratch (VMC-022c)."
  def light_compute(%__MODULE__{} = blocks) do
    :ok = Native.light_compute(blocks.ref)
  end

  @doc """
  Relight after the blocks at `positions` changed; returns the region's chunks
  whose light changed. Large batches run on a dirty scheduler.
  """
  def light_update(%__MODULE__{} = blocks, positions) when is_list(positions) do
    update =
      if length(positions) > 64, do: &Native.light_update_dirty/2, else: &Native.light_update/2

    {:ok, chunks} = update.(blocks.ref, positions)
    chunks
  end

  @doc """
  A chunk's light image (`Valimc.Anvil.Light` layout). The region is lit on the
  first request (until then edits need no relighting: the first light computation
  sees them).
  """
  def light_image(%__MODULE__{} = blocks, {cx, cz} = chunk) do
    case Native.light_image(blocks.ref, cx, cz) do
      {:ok, :flat} ->
        :ok = light_compute(blocks)
        light_image(blocks, chunk)

      {:ok, image} ->
        image
    end
  end

  @doc """
  Install generated column images (`chunk => image`, VMC-075), all or nothing,
  and relight once; returns the region's chunks whose light changed (none before
  the region is lit: its first computation sees them).
  """
  def put_columns(%__MODULE__{} = blocks, images) when is_map(images) do
    list = for {{cx, cz}, image} <- images, do: {cx, cz, image}

    case Native.put_columns_lit(blocks.ref, list) do
      {:ok, chunks} -> {:ok, chunks}
      {:error, _} = error -> error
    end
  end

  @doc """
  `/fillbiome` (VMC-053j4): sets the biome cells of `chunks` inside the block box
  `{min, max}` (whose biome is in `filter`, nil for any) to `biome` at once;
  `{:ok, {changed_cells, [{cx, cz, image}]}}`, the images to persist.
  """
  def fill_biomes(%__MODULE__{} = blocks, chunks, {min, max}, biome, filter) do
    plains = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")
    Native.fill_biomes(blocks.ref, chunks, min, max, biome, filter, plains)
  end

  @doc "A chunk's biome containers as `chunks_biomes` carries them."
  def encode_biomes(%__MODULE__{} = blocks, {cx, cz}) do
    plains = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")

    Native.encode_biomes(
      blocks.ref,
      cx,
      cz,
      plains,
      Data.global_biome_bits(),
      Valimc.Dimension.section_window()
    )
  end

  @doc "A chunk's column image for the region log, or `:flat` for the base profile."
  def column_image(%__MODULE__{} = blocks, {cx, cz}) do
    case Native.column_image(blocks.ref, cx, cz) do
      {:ok, image} -> {:ok, image}
      {:error, _} = error -> error
    end
  end

  def get(%__MODULE__{} = blocks, {x, y, z}) do
    case Native.get_blocks(blocks.ref, <<x::32-signed, y::32-signed, z::32-signed>>) do
      {:ok, <<block::16>>} -> block
      {:error, _} -> Chunk.base(y)
    end
  end

  @doc "A `position => block` map; out-of-region positions read the base profile."
  def get_many(%__MODULE__{} = blocks, positions) do
    positions = Enum.uniq(positions)

    packed =
      for {x, y, z} <- positions, into: <<>>, do: <<x::32-signed, y::32-signed, z::32-signed>>

    case Native.get_blocks(blocks.ref, packed) do
      {:ok, states} ->
        Map.new(Enum.zip(positions, for(<<state::16 <- states>>, do: state)))

      {:error, _} ->
        Map.new(positions, &{&1, get(blocks, &1)})
    end
  end

  @doc "Apply a `position => block` map atomically (all or nothing)."
  def put(%__MODULE__{}, changes) when map_size(changes) == 0, do: :ok

  def put(%__MODULE__{} = blocks, changes) when is_map(changes) do
    packed =
      for {{x, y, z}, block} <- changes,
          into: <<>>,
          do: <<x::32-signed, y::32-signed, z::32-signed, block::32>>

    Native.dispatch(:set_blocks, div(byte_size(packed), 16), [blocks.ref, packed])
  end

  @doc """
  Section data and heightmaps for a chunk packet, or `:flat` for an untouched
  overworld chunk (callers use the cached flat packet). Only the owner's
  dimension's sections are encoded. The owner hands the result to a worker.
  """
  def encode(%__MODULE__{} = blocks, {cx, cz} = chunk) do
    biome = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")

    case Native.encode_chunk(
           blocks.ref,
           cx,
           cz,
           biome,
           Data.global_block_bits(),
           Data.global_biome_bits(),
           Valimc.Dimension.section_window()
         ) do
      {:ok, :flat} ->
        :flat

      {:ok, {sections, surface, motion}} ->
        %{chunk: chunk, sections: sections, surface: surface, motion: motion}
    end
  end

  @doc """
  A chunk's states (24 × 4096 big-endian u16, section index order) and biome
  registry ids (24 × 64); flat columns report plains.
  """
  def dump_column(%__MODULE__{} = blocks, {cx, cz}) do
    plains = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")

    case Native.dump_column(blocks.ref, cx, cz, plains) do
      {:ok, {states, biomes}} -> {:ok, states, biomes}
      {:error, _} = error -> error
    end
  end

  @doc """
  The biome identifier at a block as vanilla's `Level.getBiome` reads it (the
  fuzzed zoom with the world's hashed seed), or nil when the quart it picks lies
  outside the region.
  """
  def biome(%__MODULE__{} = blocks, zoom_seed, {x, y, z}) do
    plains = Data.registry_id("minecraft:worldgen/biome", "minecraft:plains")

    case Native.region_biome(blocks.ref, zoom_seed, {x, y, z}, plains) do
      {:ok, nil} -> nil
      {:ok, id} -> Data.registry_name("minecraft:worldgen/biome", id)
      {:error, _} -> nil
    end
  end

  @doc """
  A chunk's owned block-entity carriers (single chests, furnaces) and those
  without data (end portals) as `position => block`.
  """
  def chunk_entities(%__MODULE__{} = blocks, {cx, cz}) do
    states = owned_states() ++ Valimc.Physics.BlockEntities.plain_states()
    {:ok, found} = Native.chunk_find(blocks.ref, cx, cz, states)

    for <<x::32-signed, y::32-signed, z::32-signed, block::16 <- found>>,
      into: %{},
      do: {{x, y, z}, block}
  end

  defp owned_states do
    case :persistent_term.get({__MODULE__, :owned_states}, nil) do
      nil ->
        states =
          for state <- 0..(Data.block_state_count() - 1),
              Valimc.Block.block_entity(state) != nil,
              do: state

        :persistent_term.put({__MODULE__, :owned_states}, states)
        states

      states ->
        states
    end
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

  @doc "Mark the states whose random ticks this region handles (VMC-066)."
  def random_ticking(%__MODULE__{} = blocks, states) do
    size = div(Valimc.Protocol.Data.block_state_count() + 7, 8)
    set = MapSet.new(states)

    bitmap =
      for byte <- 0..(size - 1), into: <<>> do
        bits =
          for bit <- 7..0//-1,
              into: <<>>,
              do: <<if(MapSet.member?(set, byte * 8 + bit), do: 1, else: 0)::1>>

        bits
      end

    :ok = Native.set_random_ticking(blocks.ref, bitmap)
  end

  @doc "Sampled random tick hits `{position, state}` for this tick (vanilla positions per section)."
  def random_ticks(%__MODULE__{} = blocks, per_section) do
    sections = Valimc.config(:region_size) ** 2 * 24

    {:ok, hits} =
      Native.dispatch(:random_ticks, per_section * sections, [blocks.ref, per_section])

    for <<x::32-signed, y::32-signed, z::32-signed, state::16 <- hits>>, do: {{x, y, z}, state}
  end
end
