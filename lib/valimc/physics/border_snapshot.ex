defmodule Valimc.Physics.BorderSnapshot do
  @moduledoc "Pure stationary border observations; no border owner, resizing or gameplay authority."
  alias Valimc.Physics.{Box, Shape, VoxelOps}
  defstruct center_x: 0.0, center_z: 0.0, diameter: 59_999_968.0, absolute_max: 29_999_984
  @corner_epsilon 9.999999747378752e-6
  @extent 60_000_000.0

  def new(x, z, diameter, absolute_max \\ 29_999_984) do
    border = %__MODULE__{center_x: x, center_z: z, diameter: diameter, absolute_max: absolute_max}

    if valid?(border),
      do: {:ok, %{border | center_x: x * 1.0, center_z: z * 1.0, diameter: diameter * 1.0}},
      else: {:error, :invalid_border_observation}
  end

  def valid?(%__MODULE__{center_x: x, center_z: z, diameter: d, absolute_max: m} = border),
    do:
      map_size(border) == 5 and coordinate?(x) and coordinate?(z) and is_number(d) and
        d >= 0 and d <= 59_999_968 and is_integer(m) and m in 0..29_999_984

  def valid?(_), do: false

  def bounds(border) do
    if valid?(border) do
      %{center_x: x, center_z: z, diameter: d, absolute_max: m} = border
      clamp = &min(max(&1, -m * 1.0), m * 1.0)
      {:ok, {clamp.(x - d / 2), clamp.(z - d / 2), clamp.(x + d / 2), clamp.(z + d / 2)}}
    else
      {:error, :invalid_border_observation}
    end
  end

  def contains?(border, {x, z}) do
    with true <- point?(x, z),
         {:ok, bounds} <- bounds(border) do
      {:ok, within?(bounds, x, z, 0.0)}
    else
      false -> {:error, :invalid_border_query}
      error -> error
    end
  end

  def contains?(border, {x, _, z, a, _, c} = box) do
    with true <- Box.valid?(box), {:ok, bounds} <- bounds(border) do
      {:ok,
       within?(bounds, x, z, 0.0) and
         within?(bounds, a - @corner_epsilon, c - @corner_epsilon, 0.0)}
    else
      false -> {:error, :invalid_border_query}
      error -> error
    end
  end

  def contains?(_, _), do: {:error, :invalid_border_query}

  def distance(border, {x, z}) do
    with true <- point?(x, z),
         {:ok, bounds} <- bounds(border) do
      {:ok, distance_to(bounds, x, z)}
    else
      false -> {:error, :invalid_border_query}
      error -> error
    end
  end

  def distance(_, _), do: {:error, :invalid_border_query}

  def no_collision?(border, subject, box) do
    with true <- query?(box) and (is_nil(subject) or match?({_, _}, subject)),
         {:ok, bounds} <- bounds(border),
         {:ok, close} <- close?(bounds, subject, box) do
      {:ok, not close or not intersects?(bounds, box)}
    else
      false -> {:error, :invalid_border_query}
      error -> error
    end
  end

  defp close?(_, nil, _), do: {:ok, false}

  defp close?(bounds, {x, z}, {a, _, c, b, _, d}) do
    if point?(x, z) do
      margin = max(max(abs(b - a), abs(d - c)), 1.0)
      {:ok, distance_to(bounds, x, z) < margin * 2 and within?(bounds, x, z, margin)}
    else
      {:error, :invalid_border_query}
    end
  end

  defp intersects?({a, c, b, d}, box) do
    query = VoxelOps.world_box(box)
    x0 = floor(a) * 1.0
    x1 = ceil(b) * 1.0
    z0 = floor(c) * 1.0
    z1 = ceil(d) * 1.0

    if x0 == x1 or z0 == z1 do
      universe = VoxelOps.world_box({-@extent, -@extent, -@extent, @extent, @extent, @extent})
      VoxelOps.intersects?(universe, query)
    else
      # Keep the union's internal planes: four independent half-space tests
      # differ from native voxel merging at epsilon-sized corner intersections.
      xs = {-@extent, x0, x1, @extent}
      zs = {-@extent, z0, z1, @extent}

      boxes =
        for x <- 0..2,
            z <- 0..2,
            x != 1 or z != 1,
            do: {elem(xs, x), -@extent, elem(zs, z), elem(xs, x + 1), @extent, elem(zs, z + 1)}

      outside = %Shape{
        axes: {xs, {-@extent, @extent}, zs},
        sizes: {3, 1, 3},
        bits: <<239, 1>>,
        boxes: boxes
      }

      VoxelOps.intersects?(outside, query)
    end
  end

  defp within?({a, c, b, d}, x, z, margin),
    do: x >= a - margin and x < b + margin and z >= c - margin and z < d + margin

  defp distance_to({a, c, b, d}, x, z), do: min(min(min(x - a, b - x), z - c), d - z)
  defp coordinate?(n), do: is_number(n) and abs(n) <= 59_999_999
  defp point?(x, z), do: coordinate?(x) and coordinate?(z)

  defp query?(box),
    do: Box.valid?(box) and Enum.all?(Tuple.to_list(box), &coordinate?/1)
end
