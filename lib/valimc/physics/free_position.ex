defmodule Valimc.Physics.FreePosition do
  @moduledoc "Nearest point in a bounded box after subtracting collision boxes (VMC-043e13)."
  @epsilon 1.0e-7

  @doc "The nearest remaining point, or nil when obstacles cover the search volume."
  def closest(space, point, obstacles) do
    obstacles
    |> Enum.reduce([space], fn obstacle, boxes ->
      Enum.flat_map(boxes, &subtract(&1, obstacle))
    end)
    |> Enum.sort()
    |> Enum.reduce(nil, fn box, best ->
      candidate = clamp(point, box)
      distance = distance(point, candidate)

      case best do
        {previous, _} when previous <= distance -> best
        _ -> {distance, candidate}
      end
    end)
    |> case do
      nil -> nil
      {_, point} -> point
    end
  end

  defp subtract({x0, y0, z0, x1, y1, z1} = box, {a0, b0, c0, a1, b1, c1}) do
    {a0, b0, c0, a1, b1, c1} =
      {max(x0, a0), max(y0, b0), max(z0, c0), min(x1, a1), min(y1, b1), min(z1, c1)}

    if a1 - a0 <= @epsilon or b1 - b0 <= @epsilon or c1 - c0 <= @epsilon do
      [box]
    else
      [
        {x0, y0, z0, a0, y1, z1},
        {a1, y0, z0, x1, y1, z1},
        {a0, y0, z0, a1, b0, z1},
        {a0, b1, z0, a1, y1, z1},
        {a0, b0, z0, a1, b1, c0},
        {a0, b0, c1, a1, b1, z1}
      ]
      |> Enum.filter(fn {x0, y0, z0, x1, y1, z1} ->
        x1 - x0 > @epsilon and y1 - y0 > @epsilon and z1 - z0 > @epsilon
      end)
    end
  end

  defp clamp({x, y, z}, {x0, y0, z0, x1, y1, z1}),
    do: {min(max(x, x0), x1), min(max(y, y0), y1), min(max(z, z0), z1)}

  defp distance({x, y, z}, {a, b, c}),
    do: (x - a) * (x - a) + (y - b) * (y - b) + (z - c) * (z - c)
end
