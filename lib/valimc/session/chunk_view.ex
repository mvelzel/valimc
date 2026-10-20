defmodule Valimc.Session.ChunkView do
  @moduledoc """
  Which chunks a player tracks (VMC-070), as vanilla 26.3's `ChunkTrackingView`.

  A view is `{center, distance}` or `nil` (nothing tracked). The distance is the
  client's requested view distance clamped to `2..server_distance()`; the server
  distance is the `view_distance` setting clamped to `2..32`. A chunk is tracked
  when its offset from the center, less a ring of two chunks, lies strictly inside
  a circle of that radius: the extra ring gives the client the neighbours it needs
  to render the edge, so distance 2 is a full 7×7 square.
  """

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

  def chunks({{cx, cz}, _} = view) do
    for(chunk <- box(view), contains?(view, chunk), do: chunk)
    |> Enum.sort_by(fn {x, z} -> (x - cx) * (x - cx) + (z - cz) * (z - cz) end)
  end

  @doc """
  The chunks entering and leaving when the view changes from `from` to `to`, as
  `{entering, leaving}`; only their union's bounding box is visited.
  """
  def difference(view, view), do: {[], []}

  def difference(from, to) do
    if from != nil and to != nil and overlaps?(from, to) do
      {x0, z0, x1, z1} = union(bounds(from), bounds(to))

      for x <- x0..x1, z <- z0..z1, reduce: {[], []} do
        {entering, leaving} ->
          case {contains?(from, {x, z}), contains?(to, {x, z})} do
            {false, true} -> {[{x, z} | entering], leaving}
            {true, false} -> {entering, [{x, z} | leaving]}
            _ -> {entering, leaving}
          end
      end
    else
      {chunks(to), chunks(from)}
    end
  end

  @doc "Whether any chunk of the rectangle `{x0, z0, x1, z1}` (inclusive) is tracked."
  def intersects?(nil, _rect), do: false

  def intersects?({{cx, cz}, _} = view, {x0, z0, x1, z1}),
    do: contains?(view, {cx |> max(x0) |> min(x1), cz |> max(z0) |> min(z1)})

  defp box(view) do
    {x0, z0, x1, z1} = bounds(view)
    for x <- x0..x1, z <- z0..z1, do: {x, z}
  end

  defp bounds({{cx, cz}, distance}),
    do: {cx - distance - 1, cz - distance - 1, cx + distance + 1, cz + distance + 1}

  defp overlaps?(a, b) do
    {ax0, az0, ax1, az1} = bounds(a)
    {bx0, bz0, bx1, bz1} = bounds(b)
    ax0 <= bx1 and ax1 >= bx0 and az0 <= bz1 and az1 >= bz0
  end

  defp union({ax0, az0, ax1, az1}, {bx0, bz0, bx1, bz1}),
    do: {min(ax0, bx0), min(az0, bz0), max(ax1, bx1), max(az1, bz1)}
end
