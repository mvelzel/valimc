defmodule Valimc.World.Blocks do
  @moduledoc """
  Paletted section storage for one region, held in a Rust resource.

  The handle is mutable and owned by the region process: only that process may
  read or change it, and it must not be sent to other processes. Readers elsewhere
  receive values (block maps, encoded binaries) instead.

  Positions outside the region or the world height read as the flat base profile,
  matching the edit-map semantics this replaces; VMC-065 makes them explicit errors.
  """
  alias Valimc.Data.Grid
  alias Valimc.Native
  alias Valimc.Protocol.Data
  alias Valimc.World.Chunk
  import Bitwise

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
    size = Grid.region_size()
    layers = for y <- Grid.min_y()..319, into: <<>>, do: <<Chunk.base(y)::16>>
    {:ok, ref} = Native.region_new(rx * size, rz * size, size, layers, @budget)
    # The owner's dimension may have no sky light (the Nether, VMC-026b).
    unless Valimc.World.Dimension.facts().sky_light, do: :ok = Native.light_sky(ref, false)
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
  A chunk's light image (`Valimc.Storage.Anvil.Light` layout), nil while light does
  not know the chunk; with `sections` (`{sky_bits, block_bits}`, a bit per
  stored section) only those layers.
  """
  def light_image(%__MODULE__{} = blocks, {cx, cz}, sections \\ nil) do
    {:ok, image} = Native.light_image(blocks.ref, cx, cz, sections)
    image
  end

  @doc """
  Install generated columns from their handles (`chunk => handle`,
  `column_handle/2`, VMC-081c2), all or nothing, with the light they were
  generated with; returns the region's light changes (`light_update/2`).
  """
  def put_columns(%__MODULE__{} = blocks, handles) when is_map(handles) do
    list = for {{cx, cz}, handle} <- handles, do: {cx, cz, handle}
    Native.dispatch(:put_columns, length(list), [blocks.ref, list])
  end

  @doc """
  A column image (with the light it was lit with alone, if stored) decoded
  and checked once, for `put_columns/2` and neighbours' rings to share
  without decoding. `{:background, chunk, spec}` makes it on a generation
  thread (VMC-081c) with its chunk's packet parts (`packet_spec/1`,
  `prepared/2`).
  """
  def column_handle(image), do: Native.column_handle(image)

  def column_handle(image, {:background, _chunk, nil}),
    do: Native.background(&Native.column_handle_background(&1, image, nil))

  def column_handle(image, {:background, {cx, cz}, spec}) do
    :ok = carriers_installed()
    Native.background(&Native.column_handle_background(&1, image, {cx, cz, spec}))
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
      Valimc.World.Dimension.section_window()
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

  @doc "The states of the box `min..max` in this region, x fastest, then y, then z."
  def read_box(%__MODULE__{} = blocks, min, max), do: Native.read_box(blocks.ref, min, max)

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
  Keep or drop (nil) moving pistons' block entities (VMC-048b,
  `position => {moved, direction, extending?, source?, progress, progress_o,
  last_ticked, order}`) beside the cells, where snapshots and the block rules
  read them. Returns the chunks they touch.
  """
  def put_pistons(%__MODULE__{}, pistons) when map_size(pistons) == 0, do: []

  def put_pistons(%__MODULE__{} = blocks, pistons) do
    {kept, gone} = Enum.split_with(pistons, fn {_, moving} -> moving != nil end)
    kept = for entry <- kept, into: <<>>, do: Valimc.Blocks.MovingPistons.pack(entry)

    gone =
      for {{x, y, z}, nil} <- gone, into: <<>>, do: <<x::32-signed, y::32-signed, z::32-signed>>

    {:ok, chunks} = Native.set_pistons(blocks.ref, kept, gone)
    chunks
  end

  @doc "Moving pistons' block entities in chunk `{cx, cz}` as `put_pistons/2` takes them."
  def chunk_pistons(%__MODULE__{} = blocks, {cx, cz}) do
    {:ok, packed} = Native.chunk_pistons(blocks.ref, cx, cz)
    for <<record::binary-size(40) <- packed>>, do: Valimc.Blocks.MovingPistons.unpack(record)
  end

  @doc """
  Section data and heightmaps for a chunk packet, or `:flat` for an untouched
  overworld chunk (callers use the cached flat packet). Only the owner's
  dimension's sections are encoded. The owner hands the result to a worker.
  """
  def encode(%__MODULE__{} = blocks, {cx, cz} = chunk) do
    {biome, bits, biome_bits, window} = packet_spec()

    case Native.encode_chunk(blocks.ref, cx, cz, biome, bits, biome_bits, window) do
      {:ok, :flat} ->
        :flat

      {:ok, {sections, surface, motion}} ->
        %{chunk: chunk, sections: sections, surface: surface, motion: motion}
    end
  end

  @doc """
  How `dimension`'s chunk packets encode sections: `{default_biome,
  block_bits, biome_bits, section_window}`.
  """
  def packet_spec(dimension \\ Valimc.World.Dimension.current()) do
    {Data.registry_id("minecraft:worldgen/biome", "minecraft:plains"), Data.global_block_bits(),
     Data.global_biome_bits(), Valimc.World.Dimension.section_window(dimension)}
  end

  @doc """
  What `chunk`'s generation job prepared of its packet (VMC-081c2), once
  and while its column is as generated: `{encode/2's result,
  chunk_entities/2's}`, else nil.
  """
  def prepared(%__MODULE__{} = blocks, {cx, cz} = chunk) do
    case Native.chunk_prepared(blocks.ref, cx, cz, packet_spec()) do
      {:ok, {sections, surface, motion, found}} ->
        {%{chunk: chunk, sections: sections, surface: surface, motion: motion}, carriers(found)}

      {:ok, nil} ->
        nil
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
  Sky and block light (`{sky, block}`) at a block of the region or its ring,
  nil where its light does not know the chunk (VMC-043b).
  """
  def light(%__MODULE__{} = blocks, position) do
    case Native.region_light(blocks.ref, [position]) do
      {:ok, [light]} -> light
      _ -> nil
    end
  end

  @doc """
  A chunk's owned block-entity carriers (single chests, furnaces) and those
  without data (end portals) as `position => block`.
  """
  def chunk_entities(%__MODULE__{} = blocks, {cx, cz}) do
    :ok = carriers_installed()
    {:ok, found} = Native.chunk_carriers(blocks.ref, cx, cz)
    carriers(found)
  end

  defp carriers(found) do
    for <<x::32-signed, y::32-signed, z::32-signed, block::16 <- found>>,
      into: %{},
      do: {{x, y, z}, block}
  end

  @doc """
  Install the block-entity carriers (`chunk_entities/2`) natively, once per
  VM: the owned carriers and those without data.
  """
  def carriers_installed do
    if :persistent_term.get({__MODULE__, :carriers}, false) do
      :ok
    else
      owned =
        for state <- 0..(Data.block_state_count() - 1),
            Valimc.Blocks.block_entity(state) != nil,
            do: state

      :ok = Native.carriers_install(owned ++ Valimc.Blocks.BlockEntityTypes.plain_states())
      :persistent_term.put({__MODULE__, :carriers}, true)
    end
  end

  @doc "The cells of chunk `{cx, cz}` holding any of `states`: `[{position, state}]`."
  def find(%__MODULE__{} = blocks, {cx, cz}, states) do
    {:ok, found} = Native.chunk_find(blocks.ref, cx, cz, states)
    for <<x::32-signed, y::32-signed, z::32-signed, block::16 <- found>>, do: {{x, y, z}, block}
  end

  @doc "A complete chunk packet (the reference shape of `Chunk.encode/2`)."
  def packet(%__MODULE__{} = blocks, chunk) do
    case encode(blocks, chunk) do
      :flat -> Chunk.encode(chunk, %{})
      encoded -> Chunk.packet(encoded, chunk_entities(blocks, chunk))
    end
  end

  @doc """
  Snapshots of `chunks` (`{chunk, previous}`, `previous` its last published
  handle or nil) at `revision`, in order (see `BlockSnapshot`).
  """
  def snapshots(%__MODULE__{} = blocks, chunks, revision) do
    {:ok, handles} =
      Native.snapshot_publish(
        blocks.ref,
        for({{cx, cz}, previous} <- chunks, do: {cx, cz, previous}),
        revision
      )

    handles
  end

  def touched_chunks(%__MODULE__{} = blocks) do
    {:ok, chunks} = Native.touched_chunks(blocks.ref)
    chunks
  end

  @doc """
  Mark the states whose random ticks the block rules run (`rules`) and those
  the owner runs itself (`owner`, VMC-066); the sections count every
  randomly ticking state, as vanilla's do (VMC-081g1).
  """
  def random_ticking(%__MODULE__{} = blocks, rules, owner) do
    :ok =
      Native.set_random_ticking(
        blocks.ref,
        bitmap(Valimc.World.Growth.ticking_states()),
        bitmap(rules),
        bitmap(owner)
      )
  end

  @doc """
  Mark the redstone contact states (`contacts`: plates, buttons, tripwire)
  and the portal states (`portals`), whose cells the region counts so work
  only they can start is skipped where there are none (VMC-081j).
  """
  def counted_states(%__MODULE__{} = blocks, contacts, portals) do
    :ok = Native.set_counted_states(blocks.ref, bitmap(contacts), bitmap(portals))
  end

  @doc """
  The chunks of the regions of `blocks` holding a redstone contact cell, or
  `:all` where a region does not count them.
  """
  def contact_chunks(blocks),
    do: Native.contact_chunks(for(%__MODULE__{ref: ref} <- blocks, do: ref))

  # One bit per state id, least significant first in each byte.
  defp bitmap(states) do
    bytes =
      Enum.reduce(states, %{}, fn state, acc ->
        Map.update(acc, div(state, 8), 1 <<< rem(state, 8), &(&1 ||| 1 <<< rem(state, 8)))
      end)

    size = div(Valimc.Protocol.Data.block_state_count() + 7, 8)
    for byte <- 0..(size - 1), into: <<>>, do: <<Map.get(bytes, byte, 0)>>
  end
end
