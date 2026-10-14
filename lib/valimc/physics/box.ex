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

  defp finite_coordinates?(box),
    do: box |> Tuple.to_list() |> Enum.all?(&(is_number(&1) and abs(&1) <= @bound))
end
