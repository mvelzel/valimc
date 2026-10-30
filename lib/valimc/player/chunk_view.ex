defmodule Valimc.Player.ChunkView do
  @moduledoc """
  Which chunks a player tracks (VMC-070), as vanilla 26.3's `ChunkTrackingView`.

  A view is `{center, distance}` or `nil` (nothing tracked). The distance is the
  client's requested view distance clamped to `2..server_distance()`; the server
  distance is the `view_distance` setting clamped to `2..32`. A chunk is tracked
  when its offset from the center, less a ring of two chunks, lies strictly inside
  a circle of that radius: the extra ring gives the client the neighbours it needs
  to render the edge, so distance 2 is a full 7×7 square.
  """
  alias Valimc.Data.Grid

  @min 2
  @max 32

  @doc "The server's view distance (`view-distance`), as the login packet carries it."
  def server_distance, do: Valimc.config(:view_distance) |> max(@min) |> min(@max)

  @doc "The distance a player tracks for the view distance its client requested."
  def distance(requested) when is_integer(requested),
    do: requested |> max(@min) |> min(server_distance())

  def contains?(nil, _chunk), do: false

  def contains?({{cx, cz}, distance}, {x, z}) do
    dx = max(0, abs(x - cx) - 2)
    dz = max(0, abs(z - cz) - 2)
    dx * dx + dz * dz < distance * distance
  end

  @doc "Every tracked chunk, nearest to the center first."
  def chunks(nil), do: []

  def chunks({{cx, cz}, distance} = view) do
    for(
      x <- (cx - distance - 1)..(cx + distance + 1),
      {z0, z1} <- [span(view, x)],
      z <- z0..z1,
      do: {x, z}
    )
    |> Enum.sort_by(fn {x, z} -> (x - cx) * (x - cx) + (z - cz) * (z - cz) end)
  end

  @doc """
  The chunks entering and leaving when the view changes from `from` to `to`, as
  `{entering, leaving}`. Overlapping views are compared column by column, each
  column's tracked chunks being one run (`span/2`), so the work is the columns
  and the chunks that changed, not the views' area (VMC-081k).
  """
  def difference(view, view), do: {[], []}

  def difference(from, to) do
    if from != nil and to != nil and overlaps?(from, to) do
      {x0, _, x1, _} = union(bounds(from), bounds(to))
      columns_difference(&span(from, &1), &span(to, &1), x0, x1)
    else
      {chunks(to), chunks(from)}
    end
  end

  @doc """
  The chunks entering and leaving when the square of chunks within Chebyshev
  distance `radius` of `center` (`{center, radius}`, a simulation distance) moves
  from `from` to `to`, as `{entering, leaving}`; nil is no square.
  """
  def square_difference(square, square), do: {[], []}

  def square_difference(from, to) do
    {x0, x1} =
      [from, to]
      |> Enum.reject(&is_nil/1)
      |> Enum.map(fn {{cx, _}, r} -> {cx - r, cx + r} end)
      |> Enum.reduce(fn {a0, a1}, {b0, b1} -> {min(a0, b0), max(a1, b1)} end)

    columns_difference(&square_span(from, &1), &square_span(to, &1), x0, x1)
  end

  defp square_span(nil, _x), do: nil

  defp square_span({{cx, cz}, r}, x) when x >= cx - r and x <= cx + r, do: {cz - r, cz + r}
  defp square_span(_square, _x), do: nil

  # Column by column (x ascending, z ascending, each list built by prepending,
  # as a scan of the bounding box would be): what `to` holds beyond `from`'s run
  # and `from` beyond `to`'s.
  defp columns_difference(from, to, x0, x1) do
    Enum.reduce(x0..x1, {[], []}, fn x, {entering, leaving} ->
      a = from.(x)
      b = to.(x)
      {outside(b, a, x, entering), outside(a, b, x, leaving)}
    end)
  end

  defp outside(nil, _other, _x, acc), do: acc
  defp outside({z0, z1}, nil, x, acc), do: prepend(x, z0, z1, acc)

  defp outside({z0, z1}, {o0, o1}, x, acc) do
    acc = prepend(x, z0, min(z1, o0 - 1), acc)
    prepend(x, max(z0, o1 + 1), z1, acc)
  end

  defp prepend(x, z0, z1, acc) when z0 <= z1,
    do: Enum.reduce(z0..z1, acc, &[{x, &1} | &2])

  defp prepend(_x, _z0, _z1, acc), do: acc

  # The tracked chunks of column `x`, one run `{z0, z1}` or nil: `contains?/2`
  # solved for z.
  defp span({{cx, cz}, distance}, x) do
    a = max(0, abs(x - cx) - 2)
    rest = distance * distance - a * a

    if rest > 0 do
      b = isqrt(rest - 1) + 2
      {cz - b, cz + b}
    end
  end

  defp isqrt(n) do
    r = trunc(:math.sqrt(n))

    cond do
      r * r > n -> r - 1
      (r + 1) * (r + 1) <= n -> r + 1
      true -> r
    end
  end

  @doc "Whether any chunk of the rectangle `{x0, z0, x1, z1}` (inclusive) is tracked."
  def intersects?(nil, _rect), do: false

  def intersects?({{cx, cz}, _} = view, {x0, z0, x1, z1}),
    do: contains?(view, {cx |> max(x0) |> min(x1), cz |> max(z0) |> min(z1)})

  defp bounds({{cx, cz}, distance}),
    do: {cx - distance - 1, cz - distance - 1, cx + distance + 1, cz + distance + 1}

  defp overlaps?(a, b) do
    {ax0, az0, ax1, az1} = bounds(a)
    {bx0, bz0, bx1, bz1} = bounds(b)
    ax0 <= bx1 and ax1 >= bx0 and az0 <= bz1 and az1 >= bz0
  end

  defp union({ax0, az0, ax1, az1}, {bx0, bz0, bx1, bz1}),
    do: {min(ax0, bx0), min(az0, bz0), max(ax1, bx1), max(az1, bz1)}

  @doc "The sections (routing keys) holding any chunk of the view."
  def regions({{cx, cz}, distance} = view, dimension) do
    size = Grid.region_size()
    {rx0, rz0} = Grid.region_key({cx - distance - 1, cz - distance - 1})
    {rx1, rz1} = Grid.region_key({cx + distance + 1, cz + distance + 1})

    for rx <- rx0..rx1,
        rz <- rz0..rz1,
        intersects?(
          view,
          {rx * size, rz * size, rx * size + size - 1, rz * size + size - 1}
        ),
        into: MapSet.new(),
        do: {dimension, rx, rz}
  end
end
