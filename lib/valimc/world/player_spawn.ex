defmodule Valimc.World.PlayerSpawn do
  @moduledoc """
  Where a player without a respawn point appears (VMC-027e), vanilla's
  `PlayerSpawnFinder.findSpawn` around the shared spawn: new players and
  respawns without a bed or anchor (those stay VMC-040).

  The suggestion is the world spawn, or the top of the column at the border's
  centre when the spawn lies outside the border
  (`Level.getWorldBorderAdjustedRespawnData`). The search visits the
  `(2r + 1)²` columns around it (at most 1024; `r` is the `respawn_radius`
  game rule, `:respawn_radius` until game rules are stored, limited by the
  distance to the border, at least 1) in an order
  that starts at a random column and steps by a fixed stride, and takes the
  first safe column (`SpawnSearch.respawn_y/1`) where a standing player's box
  meets no block and no fluid. Without one, the player stands on the first
  free space at or below the suggestion (`fixupSpawnHeight`). In adventure
  mode only that last step runs.

  Columns are read from the regions' published snapshots in the calling
  process; regions that are not loaded yet are admitted and awaited, as
  vanilla blocks on its chunk loads. The search is bounded by a deadline, after
  which the suggestion's block centre is used.
  """
  alias Valimc.Physics.{BlockShapes, CollisionContext, FluidBlocks, Shape, VoxelOps}
  alias Valimc.World
  alias Valimc.World.{Border, BlockSnapshot, Chunk, Clock, Directory, Spawn, SpawnSearch}

  # The standing player's box: 0.6F wide, 1.8F high, both widened to doubles.
  @half_width 0.30000001192092896
  @height 1.7999999523162842
  @deadline_ms 10_000

  @doc """
  The spawn position `%{x, y, z, yaw, pitch}` for a player in `mode` (the
  bottom centre of the found block, facing the world spawn's yaw).
  """
  def find(mode \\ Valimc.config(:default_game_mode)) do
    deadline = System.monotonic_time(:millisecond) + @deadline_ms

    {x, y, z} =
      try do
        suggestion = suggestion(deadline)
        search(suggestion, mode, deadline)
      catch
        :deadline -> Spawn.position()
      end

    %{x: x + 0.5, y: y * 1.0, z: z + 0.5, yaw: Spawn.yaw(), pitch: 0.0}
  end

  @doc "The search around `suggestion` for a player in `mode`."
  def search({sx, _, sz} = suggestion, mode, deadline) do
    if mode == :adventure do
      fixup(suggestion, deadline)
    else
      radius = radius(Clock.border(), sx, sz)
      side = radius * 2 + 1
      count = min(1024, side * side)
      stride = if count <= 16, do: count - 1, else: 17
      offset = :rand.uniform(count) - 1

      Enum.find_value(0..(count - 1), fn index ->
        value = rem(offset + stride * index, count)
        x = sx + rem(value, side) - radius
        z = sz + div(value, side) - radius
        column = column(x, z, deadline)

        case SpawnSearch.respawn_y(column) do
          nil -> nil
          y -> if clear?(column, x, y, z), do: {x, y, z}
        end
      end) || fixup(suggestion, deadline)
    end
  end

  @doc "The search radius: the game rule, at most the distance to the border, at least 1 next to it."
  def radius(border, sx, sz) do
    radius = max(0, Valimc.config(:respawn_radius))
    distance = floor(Border.distance(border, sx * 1.0, sz * 1.0))
    radius = if distance < radius, do: distance, else: radius
    if distance <= 1, do: 1, else: radius
  end

  # The world spawn, moved to the column top at the border's centre when it is
  # outside the border.
  defp suggestion(deadline) do
    {x, _, z} = spawn = Spawn.position()
    border = Clock.border()

    if Border.within?(border, x * 1.0, z * 1.0) do
      spawn
    else
      cx = floor(border.center_x)
      cz = floor(border.center_z)
      {cx, SpawnSearch.motion_blocking(column(cx, cz, deadline)) + 1, cz}
    end
  end

  # `fixupSpawnHeight`: up out of anything solid, then down to the first floor.
  defp fixup({x, y, z}, deadline) do
    column = column(x, z, deadline)
    min = Chunk.min_y()
    max = min + tuple_size(column) - 1
    up = Stream.iterate(y, &(&1 + 1)) |> Enum.find(&(clear?(column, x, &1, z) or &1 >= max))

    down =
      Stream.iterate(up - 1, &(&1 - 1))
      |> Enum.find(&(not clear?(column, x, &1, z) or &1 <= min))

    {x, down + 1, z}
  end

  @doc """
  Whether a standing player at the bottom centre of `{x, y, z}` meets no
  block collision and no fluid (`noCollision(null, box, true)`), from the
  column's states. Only the block below (tall shapes such as fences), the
  block itself and the one above can reach the box.
  """
  def clear?(column, x, y, z) do
    box =
      {x + 0.5 - @half_width, y * 1.0, z + 0.5 - @half_width, x + 0.5 + @half_width, y + @height,
       z + 0.5 + @half_width}

    world = VoxelOps.world_box(box)

    # Outside the world's height is air.
    Enum.all?((y - 1)..(y + 1), fn by ->
      index = by - Chunk.min_y()

      if index < 0 or index >= tuple_size(column) do
        true
      else
        state = elem(column, index)
        {:ok, %{kind: fluid}} = FluidBlocks.fetch(state)

        cond do
          fluid != :empty and by >= y ->
            false

          true ->
            case BlockShapes.fetch(state, {x, by, z}, CollisionContext.empty()) do
              {:ok, shape} -> not VoxelOps.intersects?(Shape.move(shape, {x, by, z}), world)
              _ -> false
            end
        end
      end
    end)
  end

  @doc "A column's states from the bottom up, read from its region's published snapshot."
  def column(x, z, deadline) do
    key = World.region_key(World.chunk_key(x, z))
    positions = for y <- Chunk.min_y()..319, do: {x, y, z}
    read(key, positions, deadline)
  end

  defp read(key, positions, deadline) do
    if System.monotonic_time(:millisecond) > deadline, do: throw(:deadline)

    with {:ok, {pid, epoch}} <- World.owner(key),
         {^pid, _, %{epoch: ^epoch, items: table}} <- Directory.lookup(key),
         {:ok, _revision, blocks} <- BlockSnapshot.read(table, epoch, positions) do
      positions |> Enum.map(&Map.fetch!(blocks, &1)) |> List.to_tuple()
    else
      _ ->
        Process.sleep(5)
        read(key, positions, deadline)
    end
  end
end
