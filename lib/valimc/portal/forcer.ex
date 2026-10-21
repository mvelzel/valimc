defmodule Valimc.Portal.Forcer do
  @moduledoc """
  Where a nether portal leads (VMC-026b2), as vanilla's `PortalForcer` and
  `BlockUtil` decide it: the closest portal block near the scaled position,
  the largest portal rectangle around a block, a traveller's relative place in
  a portal, and a new portal where none is found.

  Readers are functions: `read.(pos)` gives a state, `height.(x, z)` the
  MOTION_BLOCKING heightmap (one above the top motion-blocking state).
  `border` is `{min_x, min_z, max_x, max_z}` (`Valimc.World.Border.bounds/1`).
  All functions are pure.
  """
  alias Valimc.Portal.{Blocks, Shape}

  # vanilla's `1.0E-5F`, as a double.
  @epsilon 9.999999747378752e-6

  @doc "The square radius searched for an exit portal (16 into the Nether, 128 out)."
  def radius(true = _to_nether), do: 16
  def radius(false), do: 128

  @doc "The chunks whose portal blocks the search around `pos` reads (`getInSquare`)."
  def search_chunks({x, _y, z}, radius) do
    reach = Integer.floor_div(radius, 16) + 1
    {cx, cz} = {Bitwise.bsr(x, 4), Bitwise.bsr(z, 4)}

    for chunk_x <- (cx - reach)..(cx + reach),
        chunk_z <- (cz - reach)..(cz + reach),
        do: {chunk_x, chunk_z}
  end

  @doc """
  The closest portal block to `approx` among `portals` (`{position, state}`)
  in the square of `radius`, inside the border and still a portal; nearest,
  then lowest (`findClosestPortalPosition`). Equally near and low blocks are
  ordered by vanilla's POI hash order; this takes the lowest X, then Z.
  """
  def closest(portals, {ax, _ay, az} = approx, radius, border) do
    portals
    |> Enum.filter(fn {{x, _, z} = pos, state} ->
      abs(x - ax) <= radius and abs(z - az) <= radius and within?(border, pos) and
        Blocks.horizontal_axis?(state)
    end)
    |> Enum.min_by(
      fn {{x, y, z} = pos, _} -> {distance(pos, approx), y, x, z} end,
      fn -> nil end
    )
    |> case do
      nil -> :none
      {pos, _} -> {:ok, pos}
    end
  end

  @doc "Vanilla `WorldBorder.isWithinBounds` of a block position."
  def within?({min_x, min_z, max_x, max_z}, {x, _y, z}),
    do: x >= min_x and x < max_x and z >= min_z and z < max_z

  @doc "Vanilla `WorldBorder.clampToBounds(x, y, z)`: the block containing the clamped point."
  def clamp({min_x, min_z, max_x, max_z}, {x, y, z}) do
    {floor(clamp(x, min_x, max_x - @epsilon)), floor(y), floor(clamp(z, min_z, max_z - @epsilon))}
  end

  defp clamp(value, low, high), do: if(value < low, do: low, else: min(value, high))

  defp distance({x, y, z}, {a, b, c}),
    do: (x - a) * (x - a) + (y - b) * (y - b) + (z - c) * (z - c)

  ## Rectangles

  @doc """
  The largest rectangle of blocks passing `test` around `center` in the plane
  of `axis1` and `axis2`, at most `limit1` and `limit2` from it
  (`BlockUtil.getLargestRectangleAround`): `{min_corner, size1, size2}`.
  """
  def largest_rectangle(center, axis1, limit1, axis2, limit2, test) do
    {neg1, pos1} = {direction(axis1, -1), direction(axis1, 1)}
    {neg2, pos2} = {direction(axis2, -1), direction(axis2, 1)}
    negative1 = limit(test, center, neg1, limit1)
    positive1 = limit(test, center, pos1, limit1)
    centre1 = negative1
    centre_bounds = {limit(test, center, neg2, limit2), limit(test, center, pos2, limit2)}
    centre2 = elem(centre_bounds, 0)

    lower =
      Enum.reduce(1..negative1//1, [centre_bounds], fn i, [{last_min, last_max} | _] = acc ->
        at = Shape.offset(center, neg1, i)
        [{limit(test, at, neg2, last_min), limit(test, at, pos2, last_max)} | acc]
      end)

    upper =
      Enum.reduce(1..positive1//1, [centre_bounds], fn i, [{last_min, last_max} | _] = acc ->
        at = Shape.offset(center, pos1, i)
        [{limit(test, at, neg2, last_min), limit(test, at, pos2, last_max)} | acc]
      end)

    # Index 0 is the farthest negative column, `centre1` the centre.
    bounds = lower ++ tl(Enum.reverse(upper))

    {min1, min2, size1, size2} =
      Enum.reduce(centre2..0//-1, {0, 0, 0, 0}, fn i2, {_, _, s1, s2} = best ->
        columns =
          Enum.map(bounds, fn {low, high} ->
            {from, to} = {centre2 - low, centre2 + high}
            if i2 >= from and i2 <= to, do: to + 1 - i2, else: 0
          end)

        {{start, finish}, height} = max_rectangle(columns)
        new1 = 1 + finish - start
        if new1 * height > s1 * s2, do: {start, i2, new1, height}, else: best
      end)

    corner =
      center
      |> Shape.offset(direction(axis1, 1), min1 - centre1)
      |> Shape.offset(direction(axis2, 1), min2 - centre2)

    {corner, size1, size2}
  end

  defp limit(test, pos, direction, limit) do
    Enum.reduce_while(1..limit//1, 0, fn n, count ->
      if test.(Shape.offset(pos, direction, n)), do: {:cont, count + 1}, else: {:halt, count}
    end)
  end

  defp direction(:x, sign), do: {sign, 0, 0}
  defp direction(:y, sign), do: {0, sign, 0}
  defp direction(:z, sign), do: {0, 0, sign}

  # `getMaxRectangleLocation`: the largest rectangle under a histogram.
  defp max_rectangle(columns) do
    heights = List.to_tuple(columns)
    count = tuple_size(heights)

    {max_start, max_end, max_height, _stack} =
      Enum.reduce(1..count, {0, 0, 0, [0]}, fn column, {ms, me, mh, stack} ->
        height = if column == count, do: 0, else: elem(heights, column)
        {ms, me, mh, stack} = pop(heights, column, height, {ms, me, mh, stack})
        {ms, me, mh, if(stack == [], do: [column], else: stack)}
      end)

    {{max_start, max_end - 1}, max_height}
  end

  defp pop(_heights, _column, _height, {_, _, _, []} = acc), do: acc

  defp pop(heights, column, height, {ms, me, mh, [top | rest] = stack}) do
    stack_height = elem(heights, top)

    if height >= stack_height do
      {ms, me, mh, [column | stack]}
    else
      start = if rest == [], do: 0, else: hd(rest) + 1

      {ms, me, mh} =
        if stack_height * (column - start) > mh * (me - ms),
          do: {start, column, stack_height},
          else: {ms, me, mh}

      pop(heights, column, height, {ms, me, mh, rest})
    end
  end

  @doc """
  An entity's place in a portal rectangle (`PortalShape.getRelativePosition`):
  `{right, up, forward}`, the first two in 0..1 of the room the entity has.
  """
  def relative({{min_x, min_y, min_z} = _min, size1, size2}, axis, {x, y, z}, {width, height}) do
    room1 = size1 - width
    room2 = size2 - height
    {along, along_min} = if axis == :x, do: {x, min_x}, else: {z, min_z}
    {forward, forward_min} = if axis == :x, do: {z, min_z}, else: {x, min_x}

    right =
      if room1 > 0,
        do: clamp01((along - (along_min + width / 2.0)) / room1),
        else: 0.5

    up = if room2 > 0, do: clamp01((y - min_y) / room2), else: 0.0
    {right, up, forward - (forward_min + 0.5)}
  end

  defp clamp01(value), do: value |> max(0.0) |> min(1.0)

  ## Creation

  @doc """
  A new 2 × 3 portal near `origin` along `axis` (`createPortal`): the best
  spot within 16 columns (a full one with room on both sides first, then a
  partial one, else a platform floating at 70 or above), with every block it
  sets in vanilla's order. `bounds` is `{min_y, height, logical_height}`.
  Returns `{:ok, {rectangle, edits}}` or `:error` (no room in the height).
  """
  def create(read, height_at, origin, axis, {min_y, height, logical}, border) do
    direction = direction(axis, 1)
    max_y = min(min_y + height - 1, min_y + logical - 1)

    best =
      origin
      |> spiral(16, {1, 0, 0}, {0, 0, 1})
      |> Enum.reduce(%{full: nil, partial: nil}, fn {x, _, z} = column, best ->
        top = min(max_y, height_at.(x, z))

        if within?(border, column) and within?(border, Shape.offset(column, direction, 1)),
          do: column_spots(read, origin, {x, top, z}, direction, min_y, max_y, best),
          else: best
      end)

    found =
      case best do
        %{full: {_, pos}} -> {:found, pos}
        %{partial: {_, pos}} -> {:found, pos}
        _ -> :none
      end

    case found do
      {:found, pos} ->
        {:ok, {{pos, 2, 3}, frame(pos, direction) ++ portal(pos, direction, axis)}}

      :none ->
        low = max(min_y + 1, 70)
        high = max_y - 9

        if high < low do
          :error
        else
          {x, y, z} = origin
          {dx, _, dz} = direction
          pos = clamp(border, {x - dx, y |> max(low) |> min(high), z - dz})

          {:ok,
           {{pos, 2, 3},
            platform(pos, direction) ++ frame(pos, direction) ++ portal(pos, direction, axis)}}
        end
    end
  end

  # One column of the spiral, from its height down: the bottom of each run of
  # replaceable, fluid-free cells (at least 3 high, or none) that hosts a frame.
  defp column_spots(read, origin, {x, top, z}, direction, min_y, max_y, best) do
    scan(read, origin, {x, z}, top, direction, min_y, max_y, best)
  end

  defp scan(_read, _origin, _column, y, _direction, min_y, _max_y, best) when y < min_y, do: best

  defp scan(read, origin, {x, z} = column, y, direction, min_y, max_y, best) do
    if replaceable?(read, {x, y, z}) do
      first_empty = y
      bottom = descend(read, {x, z}, y, min_y)
      best = consider(read, origin, column, first_empty, bottom, direction, max_y, best)
      scan(read, origin, column, bottom - 1, direction, min_y, max_y, best)
    else
      scan(read, origin, column, y - 1, direction, min_y, max_y, best)
    end
  end

  defp descend(read, {x, z} = column, y, min_y) do
    if y > min_y and replaceable?(read, {x, y - 1, z}),
      do: descend(read, column, y - 1, min_y),
      else: y
  end

  defp consider(read, origin, {x, z}, first_empty, y, direction, max_y, best) do
    delta = first_empty - y
    pos = {x, y, z}

    if y + 4 <= max_y and (delta <= 0 or delta >= 3) and host?(read, pos, direction, 0) do
      distance = distance(pos, origin)

      best =
        if host?(read, pos, direction, -1) and host?(read, pos, direction, 1) and
             (best.full == nil or elem(best.full, 0) > distance),
           do: %{best | full: {distance, pos}},
           else: best

      if best.full == nil and (best.partial == nil or elem(best.partial, 0) > distance),
        do: %{best | partial: {distance, pos}},
        else: best
    else
      best
    end
  end

  # `canHostFrame`: solid ground under a 4 × 4 replaceable, fluid-free room.
  defp host?(read, origin, {dx, _, dz} = _direction, offset) do
    {cx, cz} = clockwise({dx, dz})

    cells = for width <- -1..2, height <- -1..3, do: {width, height}

    Enum.all?(cells, fn {width, height} ->
      {x, y, z} = origin
      pos = {x + dx * width + cx * offset, y + height, z + dz * width + cz * offset}
      if height < 0, do: Blocks.solid?(read.(pos)), else: replaceable?(read, pos)
    end)
  end

  defp clockwise({dx, dz}), do: {-dz, dx}

  defp replaceable?(read, pos) do
    state = read.(pos)
    Blocks.replaceable?(state) and not Blocks.fluid?(state)
  end

  # The floating platform's 3 × 2 floor and its air above.
  defp platform({x, y, z}, {dx, _, dz}) do
    {cx, cz} = clockwise({dx, dz})
    air = Valimc.Registry.Blocks.default_state("air")

    for box <- -1..1, width <- 0..1, height <- -1..2 do
      state = if height < 0, do: Blocks.obsidian(), else: air
      {{x + width * dx + box * cx, y + height, z + width * dz + box * cz}, state}
    end
  end

  defp frame({x, y, z}, {dx, _, dz}) do
    for width <- -1..2,
        height <- -1..3,
        width == -1 or width == 2 or height == -1 or height == 3,
        do: {{x + width * dx, y + height, z + width * dz}, Blocks.obsidian()}
  end

  defp portal({x, y, z}, {dx, _, dz}, axis) do
    state = Blocks.portal(axis)
    for width <- 0..1, height <- 0..2, do: {{x + width * dx, y + height, z + width * dz}, state}
  end

  @doc """
  `BlockPos.spiralAround(center, radius, first, second)`: the centre, then
  ever wider legs turning from `first` to `second`, 4 × radius legs in all.
  """
  def spiral(center, radius, first, second) do
    directions = List.to_tuple([first, second, negate(first), negate(second)])
    legs = 4 * radius
    start = Shape.offset(center, second, 1)

    Stream.unfold({start, -1, 0, 0}, fn {last, leg, size, index} ->
      cursor = Shape.offset(last, elem(directions, rem(leg + 4, 4)), 1)

      cond do
        index >= size and leg >= legs -> nil
        index >= size -> {cursor, {cursor, leg + 1, div(leg + 1, 2) + 1, 1}}
        true -> {cursor, {cursor, leg, size, index + 1}}
      end
    end)
  end

  defp negate({x, y, z}), do: {-x, -y, -z}
end
