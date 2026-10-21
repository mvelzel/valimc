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
  Storage for region `key`: flat terrain, then column `images` (`chunk =>
  image`, VMC-021c), then sparse `edits` on top. A region owner passes its
  `absent` chunks (not generated yet, VMC-075) to light the rest as well
  (VMC-077c): before the edits, each chunk from the light its image was
  stored with (or lit alone) and the light across the faces between them;
  then the edits relight incrementally.
  """
  def new({rx, rz} = key, edits \\ %{}, images \\ %{}, absent \\ nil) do
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

    with :ok <- restored,
         :ok <- light_init(blocks, absent),
         :ok <- put(blocks, edits) do
      if absent != nil, do: light_update(blocks, Map.keys(edits))
      {:ok, blocks}
    end
  end

  defp light_init(_blocks, nil), do: :ok

  defp light_init(blocks, absent) do
    case Native.light_init(blocks.ref, Enum.to_list(absent)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:light_init, reason}}
    end
  end

  @doc """
  Relight after the blocks at `positions` changed; returns the region's light
  changes, `{chunk, sky_sections, block_sections}` with a bit per stored
  section. A few positions relight on a normal scheduler within a budget of
  work; past it (undone in Rust), or for a larger batch, on a dirty one.
  """
  def light_update(%__MODULE__{}, []), do: []

  def light_update(%__MODULE__{} = blocks, positions) when is_list(positions) do
    case Native.dispatch(:light_update, length(positions), [blocks.ref, positions]) do
      {:ok, changes} ->
        changes

      {:error, :too_large} ->
        {:ok, changes} = Native.light_update_dirty(blocks.ref, positions)
        changes
    end
  end

  @doc """
  Column images (`chunk => image`) with each chunk's light alone stored in
  them (VMC-077c), for a dimension with or without `sky` light: generation
  and import light each chunk where it is made, and a region adopts that light
  when it installs or loads the column, so it only lets light cross the
  chunk's faces. Long work: run it in a generation job or offline, never in an
  owner. Identical images are lit once.
  """
  def lit_images(images, sky) when is_map(images) and is_boolean(sky) do
    lit =
      images
      |> Map.values()
      |> Enum.uniq()
      |> Map.new(fn image ->
        {:ok, lit} = Native.light_column_image(image, sky)
        {image, lit}
      end)

    Map.new(images, fn {chunk, image} -> {chunk, Map.fetch!(lit, image)} end)
  end

  @doc "The chunks of light changes."
  def changed_chunks(changes), do: for({chunk, _, _} <- changes, do: chunk)

  @doc """
  A chunk's light image (`Valimc.Anvil.Light` layout), nil while light does
  not know the chunk; with `sections` (`{sky_bits, block_bits}`, a bit per
  stored section) only those layers.
  """
  def light_image(%__MODULE__{} = blocks, {cx, cz}, sections \\ nil) do
    {:ok, image} = Native.light_image(blocks.ref, cx, cz, sections)
    image
  end

  @doc """
  Install generated column images (`chunk => image`, VMC-075), all or nothing,
  with the light they were generated with; returns the region's light changes
  (`light_update/2`).
  """
  def put_columns(%__MODULE__{} = blocks, images) when is_map(images) do
    list = for {{cx, cz}, image} <- images, do: {cx, cz, image}

    case Native.put_columns_lit(blocks.ref, list) do
      {:ok, changes} -> {:ok, changes}
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
