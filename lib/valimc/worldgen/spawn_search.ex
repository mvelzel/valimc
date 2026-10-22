defmodule Valimc.Worldgen.SpawnSearch do
  @moduledoc """
  Vanilla's spawn search (VMC-027d): the shared spawn of a new vanilla world
  (`MinecraftServer.setInitialSpawn`) and the safe spawn column test
  (`PlayerSpawnFinder.getLevelRespawnPos`) that player spawns reuse.

  The world spawn starts at the spawn target's origin chunk
  (`NoiseSpawnFinder`, native) at height 64, then walks vanilla's square spiral
  over the 11 × 11 chunks around it and takes the first chunk with a safe
  column, columns in X then Z order. Chunks come from the world's generator,
  exactly as regions will serve them.

  A column is safe when its motion-blocking top is in the world, it is not
  water or another liquid over the ocean floor, and scanning down from above
  that top meets a block with a full collision face on top before any fluid;
  the spawn is the block above it.
  """
  import Bitwise
  alias Valimc.Native
  alias Valimc.Data.BlockFacts
  alias Valimc.World.Chunk
  alias Valimc.Worldgen.Generator

  @world_surface 1 <<< 1
  @ocean_floor 1 <<< 3
  @motion_blocking 1 <<< 4
  @spawn_height 64
  @radius 5

  @doc """
  The world spawn `{x, y, z}` of vanilla `generator` (`{:vanilla, seed}`, or a
  `Generator.spec_of/1` spec). `columns` returns `{chunk => image}` for chunks
  (default: the generator). Options (VMC-028b): `:origin`, the generator's
  origin chunk (default: the normal preset's spawn target for the seed), and
  `:height`, its spawn height (`ChunkGenerator.getSpawnHeight`, default 64).
  """
  def world_spawn(generator, columns \\ &Generator.columns/2, opts \\ []) do
    {ox, oz} =
      Keyword.get_lazy(opts, :origin, fn ->
        {:vanilla, seed} = generator
        origin(seed)
      end)

    initial = {ox * 16 + 8, Keyword.get(opts, :height, @spawn_height), oz * 16 + 8}

    Enum.reduce_while(spiral(), initial, fn {dx, dz}, spawn ->
      chunk = {ox + dx, oz + dz}
      %{^chunk => image} = columns.(generator, [chunk])

      case spawn_in_chunk(chunk, image) do
        nil -> {:cont, spawn}
        found -> {:halt, found}
      end
    end)
  end

  @doc "The spawn target's origin chunk of `seed` (`NoiseBasedChunkGenerator.getOrigin`)."
  def origin(seed) do
    case Generator.spawn_origin(seed) do
      {x, z} -> {x >>> 4, z >>> 4}
      nil -> {0, 0}
    end
  end

  @doc "Chunk offsets in vanilla's spiral order, limited to the 11 × 11 square."
  def spiral do
    {offsets, _} =
      Enum.reduce(1..((2 * @radius + 1) ** 2), {[], {0, 0, 0, -1}}, fn _, {acc, {x, z, dx, dz}} ->
        acc = if abs(x) <= @radius and abs(z) <= @radius, do: [{x, z} | acc], else: acc

        {dx, dz} =
          if x == z or (x < 0 and x == -z) or (x > 0 and x == 1 - z),
            do: {-dz, dx},
            else: {dx, dz}

        {acc, {x + dx, z + dz, dx, dz}}
      end)

    Enum.reverse(offsets)
  end

  @doc "The first safe spawn in a generated chunk (`getSpawnPosInChunk`), or nil."
  def spawn_in_chunk({cx, cz}, image) do
    layers = for y <- Valimc.Data.Grid.min_y()..319, into: <<>>, do: <<Chunk.base(y)::16>>
    {:ok, ref} = Native.region_new(cx, cz, 1, layers, 4 * 1024 * 1024)
    :ok = Native.put_column_image(ref, cx, cz, image)

    Enum.find_value(for(x <- 0..15, z <- 0..15, do: {cx * 16 + x, cz * 16 + z}), fn {x, z} ->
      positions =
        for y <- Valimc.Data.Grid.min_y()..319,
            into: <<>>,
            do: <<x::32-signed, y::32-signed, z::32-signed>>

      {:ok, states} = Native.get_blocks(ref, positions)

      case respawn_y(List.to_tuple(for <<state::16 <- states>>, do: state)) do
        nil -> nil
        y -> {x, y, z}
      end
    end)
  end

  @doc """
  The spawn height of one column, given its states from the world's bottom
  up, or nil (`getLevelRespawnPos` outside cave worlds).
  """
  def respawn_y(column) when is_tuple(column) do
    min = Valimc.Data.Grid.min_y()
    top = height(column, @motion_blocking)
    surface = height(column, @world_surface)

    cond do
      top < min -> nil
      surface <= top and surface > height(column, @ocean_floor) -> nil
      true -> scan(column, top + 1 - min)
    end
  end

  # Above the column is air; a fluid ends the scan; a full top face is the floor.
  defp scan(_column, index) when index < 0, do: nil
  defp scan(column, index) when index >= tuple_size(column), do: scan(column, index - 1)

  defp scan(column, index) do
    state = elem(column, index)

    cond do
      BlockFacts.fluid(state).kind != :empty -> nil
      BlockFacts.flag?(state, :collision_up) -> index + 1 + Valimc.Data.Grid.min_y()
      true -> scan(column, index - 1)
    end
  end

  @doc "The `MOTION_BLOCKING` heightmap of a column."
  def motion_blocking(column), do: height(column, @motion_blocking)

  @doc "A heightmap's value (`ChunkAccess.getHeight`): the highest matching y, or below the world."
  def height(column, bit), do: height(column, bit, tuple_size(column) - 1)

  defp height(_column, _bit, index) when index < 0, do: Valimc.Data.Grid.min_y() - 1

  defp height(column, bit, index) do
    if (BlockFacts.heightmap(elem(column, index)) &&& bit) != 0,
      do: index + Valimc.Data.Grid.min_y(),
      else: height(column, bit, index - 1)
  end
end
