defmodule Valimc.World.Portal.Gateway do
  @moduledoc """
  End gateways' exits (VMC-026b4), as vanilla's `TheEndGatewayBlockEntity`
  finds and builds them (pure; readers are functions):

  - A gateway without an exit in the End looks 1,024 blocks out along its
    direction from the origin, steps back past chunks with blocks and forward
    past empty ones (16 each at most), takes the end stone there nearest the
    origin with room for a player above, or raises an end stone island at
    y 75, and puts a gateway 10 above the tallest block within 16 of it, with
    its own exit back.
  - A traveller arrives above the tallest block within 5 of 2 above the exit
    (bedrock excluded), or at the exit itself when it is exact.
  """
  alias Valimc.World.Portal.JavaRandom
  alias Valimc.Data.BlockFacts
  alias Valimc.Data.Blocks, as: Registry

  @end_stone Registry.default_state("end_stone")
  @bedrock Registry.default_state("bedrock")
  @air Registry.default_state("air")

  @doc "Vanilla `isCollisionShapeFullBlock`."
  def full?(state), do: BlockFacts.flag?(state, :full_collision)

  @doc """
  `findExitPortalXZPosTentative`: the point 1,024 blocks out along the
  gateway's direction, moved to the first chunk with blocks; `empty?.(x, z)`
  says whether the chunk holding a point has none.
  """
  def tentative({x, _y, z}, empty?) do
    {dx, dz} = normalize(x, z)
    start = {dx * 1024.0, dz * 1024.0}
    back = skip(start, {dx * -16.0, dz * -16.0}, 16, &(not empty?.(&1, &2)))
    skip(back, {dx * 16.0, dz * 16.0}, 16, empty?)
  end

  # `while (condition && limit-- > 0) step`.
  defp skip({x, z} = point, {sx, sz} = step, limit, condition) do
    if condition.(x, z) and limit > 0,
      do: skip({x + sx, z + sz}, step, limit - 1, condition),
      else: point
  end

  # `Vec3.normalize` of `(x, 0, z)`.
  defp normalize(x, z) do
    length = :math.sqrt(x * x + z * z)
    if length < 1.0e-5, do: {0.0, 0.0}, else: {x / length, z / length}
  end

  @doc "The chunk a point lies in (`Mth.floor(x / 16)`)."
  def chunk_of({x, z}), do: {floor(x / 16.0), floor(z / 16.0)}

  @doc """
  `findValidSpawnInChunk` of `chunk`, whose highest section with blocks ends
  at `top` (nil for a chunk of air only): vanilla looks for the end stone from
  y 30 up with two non-full blocks above it nearest the origin, but keeps the
  scan's mutable cursor, so when any qualifies it returns where the scan ends,
  the chunk's corner at its largest X and Z at `top`; nil when none does.
  """
  def valid_spawn(_read, _chunk, nil), do: nil

  def valid_spawn(read, {cx, cz}, top) do
    found =
      Enum.any?(
        for(
          z <- (cz * 16)..(cz * 16 + 15),
          y <- 30..top//1,
          x <- (cx * 16)..(cx * 16 + 15),
          do: {x, y, z}
        ),
        fn {x, y, z} ->
          read.({x, y, z}) == @end_stone and not full?(read.({x, y + 1, z})) and
            not full?(read.({x, y + 2, z}))
        end
      )

    if found, do: {cx * 16 + 15, top, cz * 16 + 15}
  end

  @doc """
  `findTallestBlock`: the highest full block (bedrock only when allowed) in
  the columns within `dist` of `around` (its own column only when bedrock is
  allowed), else `around`. `bounds` is `{min_y, max_y}`.
  """
  def tallest(read, {ax, _ay, az} = around, dist, bedrock, {min_y, max_y}) do
    found =
      for xd <- -dist..dist, zd <- -dist..dist, xd != 0 or zd != 0 or bedrock, reduce: nil do
        tallest ->
          floor = if tallest, do: elem(tallest, 1), else: min_y

          case column(read, ax + xd, az + zd, max_y, floor, bedrock) do
            nil -> tallest
            pos -> pos
          end
      end

    found || around
  end

  defp column(_read, _x, _z, y, floor, _bedrock) when y <= floor, do: nil

  defp column(read, x, z, y, floor, bedrock) do
    state = read.({x, y, z})

    if full?(state) and (bedrock or state != @bedrock),
      do: {x, y, z},
      else: column(read, x, z, y - 1, floor, bedrock)
  end

  @doc "Where a traveller arrives from an exit (`findExitPosition`, or the exact exit)."
  def arrival(_read, exit, true = _exact, _bounds), do: exit

  def arrival(read, {x, y, z}, false, bounds) do
    {tx, ty, tz} = tallest(read, {x, y + 2, z}, 5, false, bounds)
    {tx, ty + 1, tz}
  end

  @doc """
  The exit gateway `EndGatewayFeature` places at `origin`: the blocks of its
  3 × 5 × 3 frame in vanilla's order, the gateway at the centre.
  """
  def structure({ox, oy, oz}) do
    gateway = Registry.default_state("end_gateway")
    air = @air

    for z <- (oz - 1)..(oz + 1), y <- (oy - 2)..(oy + 2), x <- (ox - 1)..(ox + 1) do
      same_x = x == ox
      same_y = y == oy
      same_z = z == oz
      tip = abs(y - oy) == 2

      state =
        cond do
          same_x and same_y and same_z -> gateway
          same_y -> air
          tip and same_x and same_z -> @bedrock
          (same_x or same_z) and not tip -> @bedrock
          true -> air
        end

      {{x, y, z}, state}
    end
  end

  @doc """
  The island `EndIslandFeature` raises at `origin` with vanilla's random for
  the exit search (`RandomSource.create(origin.asLong())`): end stone discs
  shrinking downwards.
  """
  def island(origin) do
    random = JavaRandom.new(JavaRandom.block_long(origin))
    {n, random} = JavaRandom.next_int(random, 3)
    discs(origin, f32(n + 4.0), 0, random, [])
  end

  defp discs({ox, oy, oz} = origin, size, y, random, acc) do
    if size > 0.5 do
      reach = f32(size + 1.0)

      layer =
        for x <- floor(-size)..ceil(size),
            z <- floor(-size)..ceil(size),
            x * x + z * z <= f32(reach * reach),
            do: {{ox + x, oy + y, oz + z}, @end_stone}

      {n, random} = JavaRandom.next_int(random, 2)
      discs(origin, f32(size - f32(n + 0.5)), y - 1, random, acc ++ layer)
    else
      acc
    end
  end

  # Vanilla does this arithmetic in floats.
  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end

  @doc "Whether a chunk's sections hold only air (`getHighestFilledSectionIndex() == -1`)."
  def air?(state), do: BlockFacts.air?(state)
end
