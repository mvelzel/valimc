defmodule Valimc.Physics.Box do
  @moduledoc "Pure bounded axis-aligned boxes; coordinates are doubles in native geometry."
  @bound 60_000_000

  def new({x0, y0, z0, x1, y1, z1} = box) do
    unless finite_coordinates?(box), do: raise(ArgumentError, "invalid box coordinates")

    {min(x0, x1) * 1.0, min(y0, y1) * 1.0, min(z0, z1) * 1.0, max(x0, x1) * 1.0,
     max(y0, y1) * 1.0, max(z0, z1) * 1.0}
  end

  def new(_), do: raise(ArgumentError, "invalid box")

  def valid?({x0, y0, z0, x1, y1, z1} = box),
    do: finite_coordinates?(box) and x0 <= x1 and y0 <= y1 and z0 <= z1

  def valid?(_), do: false

  def move({x0, y0, z0, x1, y1, z1}, {dx, dy, dz}),
    do: new({x0 + dx, y0 + dy, z0 + dz, x1 + dx, y1 + dy, z1 + dz})

  def expand_towards(box, {dx, dy, dz} = movement) do
    unless valid?(box) and Enum.all?(Tuple.to_list(movement), &(is_number(&1) and abs(&1) <= 64)),
      do: raise(ArgumentError, "invalid box expansion")

    {x0, y0, z0, x1, y1, z1} = box

    new(
      {lower(x0, dx), lower(y0, dy), lower(z0, dz), upper(x1, dx), upper(y1, dy), upper(z1, dz)}
    )
  end

  def expand_towards(_, _), do: raise(ArgumentError, "invalid box expansion")
  defp lower(x, d), do: if(d < 0, do: x + d, else: x)
  defp upper(x, d), do: if(d > 0, do: x + d, else: x)

  def intersects?({ax0, ay0, az0, ax1, ay1, az1}, {bx0, by0, bz0, bx1, by1, bz1}),
    do: ax0 < bx1 and ax1 > bx0 and ay0 < by1 and ay1 > by0 and az0 < bz1 and az1 > bz0

  @doc "Native strict segment entry point, or nil; supplied geometry must be bounded."
  def clip({_, _, _, _, _, _} = box, {_, _, _} = from, {_, _, _} = to) do
    delta = subtract(to, from)
    epsilon = 1.0e-7

    t =
      Enum.reduce(0..2, nil, fn axis, best ->
        d = elem(delta, axis)

        if abs(d) > epsilon do
          plane = elem(box, axis + if(d < 0, do: 3, else: 0))
          t = (plane - elem(from, axis)) / d

          valid =
            t > 0 and t < (best || 1.0) and
              Enum.all?(0..2, fn i ->
                p = elem(from, i) + t * elem(delta, i)
                i == axis or (p > elem(box, i) - epsilon and p < elem(box, i + 3) + epsilon)
              end)

          if valid, do: t, else: best
        else
          best
        end
      end)

    if t, do: tuple(fn i -> elem(from, i) + t * elem(delta, i) end)
  end

  @doc "Native swept contact, distinct from axis-ordered movement clipping."
  def collided_along?(body, {_, _, _} = movement, boxes) when is_list(boxes) do
    unless valid?(body) and length(boxes) <= 64 and Enum.all?(boxes, &valid?/1) and
             Enum.all?(Tuple.to_list(movement), &(is_number(&1) and abs(&1) <= 64)),
           do: raise(ArgumentError, "invalid swept contact geometry")

    sizes = tuple(fn i -> elem(body, i + 3) - elem(body, i) end)
    center = tuple(fn i -> elem(body, i) + 0.5 * elem(sizes, i) end)
    destination = tuple(fn i -> elem(center, i) + elem(movement, i) end)
    half = tuple(fn i -> elem(sizes, i) * 0.5 - 1.0e-7 end)

    Enum.any?(boxes, fn {a, b, c, d, e, f} ->
      {x, y, z} = half
      expanded = new({a - x, b - y, c - z, d + x, e + y, f + z})

      contains?(expanded, center) or contains?(expanded, destination) or
        clip(expanded, center, destination) != nil
    end)
  end

  defp contains?(box, point),
    do:
      Enum.all?(0..2, &(elem(point, &1) >= elem(box, &1) and elem(point, &1) < elem(box, &1 + 3)))

  defp tuple(fun), do: {fun.(0), fun.(1), fun.(2)}
  defp subtract({x, y, z}, {a, b, c}), do: {x - a, y - b, z - c}

  defp finite_coordinates?(box),
    do: box |> Tuple.to_list() |> Enum.all?(&(is_number(&1) and abs(&1) <= @bound))
end
