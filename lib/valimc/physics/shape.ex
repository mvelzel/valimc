defmodule Valimc.Physics.Shape do
  @moduledoc "Immutable discrete collision grid; clipping retains native internal cell boundaries."
  import Bitwise
  alias Valimc.Physics.Box
  @epsilon 1.0e-7
  @axes [:x, :y, :z]
  defstruct axes: {{0.0}, {0.0}, {0.0}}, sizes: {0, 0, 0}, bits: <<>>, boxes: []

  def from_facts!(%{"axes" => axes, "sizes" => sizes, "bits" => hex, "boxes" => boxes}) do
    check(is_list(sizes) and length(sizes) == 3 and Enum.all?(sizes, &(&1 in 0..32)))
    [nx, ny, nz] = sizes
    cells = nx * ny * nz
    check(cells <= 32_768 and (cells > 0 or sizes == [0, 0, 0]))
    check(is_list(axes) and length(axes) == 3)
    check(is_binary(hex) and byte_size(hex) == 2 * div(cells + 7, 8))
    bits = Base.decode16!(hex, case: :lower)

    if rem(cells, 8) != 0,
      do: check(:binary.last(bits) >>> rem(cells, 8) == 0)

    check(is_list(boxes) and length(boxes) <= 64)

    boxes =
      Enum.map(boxes, fn values ->
        check(is_list(values) and length(values) == 6)
        box = List.to_tuple(values)
        check(Box.valid?(box))
        check(Enum.all?(values, &(abs(&1) <= 16.0)))
        box
      end)

    check(
      (cells == 0 and boxes == []) or
        (cells > 0 and boxes != [] and bits != :binary.copy(<<0>>, byte_size(bits)))
    )

    coords =
      Enum.zip_with(axes, sizes, fn values, size ->
        check(is_list(values) and length(values) == size + 1)
        check(Enum.all?(values, &(is_number(&1) and abs(&1) <= 16.0)))
        check(values |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a < b end))
        List.to_tuple(values)
      end)

    %__MODULE__{
      axes: List.to_tuple(coords),
      sizes: List.to_tuple(sizes),
      bits: bits,
      boxes: boxes
    }
  rescue
    _ -> raise ArgumentError, "invalid collision grid facts"
  end

  def from_facts!(_), do: raise(ArgumentError, "invalid collision grid facts")
  def empty?(%__MODULE__{bits: bits}), do: bits == <<>>

  def move(%__MODULE__{} = shape, {x, y, z} = offset) do
    check(Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 30_000_000)))

    if empty?(shape),
      do: shape,
      else: %{
        shape
        | axes:
            shape.axes
            |> Tuple.to_list()
            |> Enum.zip_with([x, y, z], fn values, delta ->
              values |> Tuple.to_list() |> Enum.map(&(&1 + delta)) |> List.to_tuple()
            end)
            |> List.to_tuple(),
          boxes: Enum.map(shape.boxes, &Box.move(&1, offset))
      }
  end

  def collide(%__MODULE__{} = shape, axis, box, delta) when axis in @axes do
    check(Box.valid?(box) and is_number(delta) and abs(delta) <= 64.0)

    cond do
      empty?(shape) -> delta
      abs(delta) < @epsilon -> 0.0
      true -> clip_grid(shape, axis_index(axis), box, delta)
    end
  end

  defp clip_grid(shape, axis, box, delta) do
    [a, b] = Enum.reject(0..2, &(&1 == axis))
    from_a = max(0, find_index(elem(shape.axes, a), elem(box, a) + @epsilon))

    to_a =
      min(elem(shape.sizes, a), find_index(elem(shape.axes, a), elem(box, a + 3) - @epsilon) + 1)

    from_b = max(0, find_index(elem(shape.axes, b), elem(box, b) + @epsilon))

    to_b =
      min(elem(shape.sizes, b), find_index(elem(shape.axes, b), elem(box, b + 3) - @epsilon) + 1)

    start =
      if delta > 0,
        do: find_index(elem(shape.axes, axis), elem(box, axis + 3) - @epsilon) + 1,
        else: find_index(elem(shape.axes, axis), elem(box, axis) + @epsilon) - 1

    scan(shape, axis, a, b, box, delta, start, {from_a, to_a}, {from_b, to_b})
  end

  defp scan(shape, axis, a, b, box, delta, index, ar, br) do
    cond do
      index < 0 or index >= elem(shape.sizes, axis) ->
        delta

      occupied_slice?(shape, axis, a, b, index, ar, br) ->
        if delta > 0 do
          gap = elem(elem(shape.axes, axis), index) - elem(box, axis + 3)
          if gap >= -@epsilon, do: min(delta, gap), else: delta
        else
          gap = elem(elem(shape.axes, axis), index + 1) - elem(box, axis)
          if gap <= @epsilon, do: max(delta, gap), else: delta
        end

      true ->
        scan(shape, axis, a, b, box, delta, index + if(delta > 0, do: 1, else: -1), ar, br)
    end
  end

  defp occupied_slice?(_, _, _, _, _, {from, to}, _) when from >= to, do: false
  defp occupied_slice?(_, _, _, _, _, _, {from, to}) when from >= to, do: false

  defp occupied_slice?(shape, axis, a, b, index, {af, at}, {bf, bt}) do
    Enum.any?(af..(at - 1), fn ai ->
      Enum.any?(bf..(bt - 1), fn bi ->
        point = {0, 0, 0} |> put_elem(axis, index) |> put_elem(a, ai) |> put_elem(b, bi)
        {x, y, z} = point
        bit = (x * elem(shape.sizes, 1) + y) * elem(shape.sizes, 2) + z
        (:binary.at(shape.bits, div(bit, 8)) &&& 1 <<< rem(bit, 8)) != 0
      end)
    end)
  end

  # Largest coordinate <= value, with -1/size outside the grid, as in native findIndex.
  defp find_index(coords, value), do: search(coords, value, 0, tuple_size(coords)) - 1
  defp search(_, _, low, low), do: low

  defp search(coords, value, low, high) do
    mid = div(low + high, 2)

    if value < elem(coords, mid),
      do: search(coords, value, low, mid),
      else: search(coords, value, mid + 1, high)
  end

  defp axis_index(:x), do: 0
  defp axis_index(:y), do: 1
  defp axis_index(:z), do: 2
  defp check(true), do: :ok
  defp check(false), do: raise(ArgumentError, "invalid collision geometry")
end
