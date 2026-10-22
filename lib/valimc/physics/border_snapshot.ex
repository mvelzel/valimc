defmodule Valimc.Physics.BorderSnapshot do
  @moduledoc "Pure stationary border observations; no border owner, resizing or gameplay authority."
  alias Valimc.Data.Box
  defstruct center_x: 0.0, center_z: 0.0, diameter: 59_999_968.0, absolute_max: 29_999_984
  @corner_epsilon 9.999999747378752e-6

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

  @doc """
  Whether the border leaves `box` clear for a mover at `subject` (`{x, z}`,
  or nil for an anonymous query): the kernel's border collider (VMC-077l).
  """
  def no_collision?(border, subject, box) do
    with true <- query?(box) and (is_nil(subject) or point?(subject)),
         {:ok, bounds} <- bounds(border) do
      subject = if subject, do: {elem(subject, 0) * 1.0, elem(subject, 1) * 1.0}
      {:ok, Valimc.Native.physics_border_clear(bounds, subject, floats(box))}
    else
      false -> {:error, :invalid_border_query}
      error -> error
    end
  end

  defp floats(box), do: box |> Tuple.to_list() |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()
  defp point?({x, z}), do: point?(x, z)
  defp point?(_), do: false

  defp within?({a, c, b, d}, x, z, margin),
    do: x >= a - margin and x < b + margin and z >= c - margin and z < d + margin

  defp distance_to({a, c, b, d}, x, z), do: min(min(min(x - a, b - x), z - c), d - z)
  defp coordinate?(n), do: is_number(n) and abs(n) <= 59_999_999
  defp point?(x, z), do: coordinate?(x) and coordinate?(z)

  defp query?(box),
    do: Box.valid?(box) and Enum.all?(Tuple.to_list(box), &coordinate?/1)
end
