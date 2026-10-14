defmodule Valimc.Physics.Collision do
  @moduledoc "Bounded pure shape clipping. Region/tick ownership is outside these calculations."
  alias Valimc.Physics.{Box, Shape}
  @max_shapes 128

  def clip(axis, box, shapes, delta) when axis in [:x, :y, :z] and is_list(shapes) do
    shapes = Enum.take(shapes, @max_shapes + 1)

    unless length(shapes) <= @max_shapes and Box.valid?(box) and is_number(delta) and
             abs(delta) <= 64.0,
           do: raise(ArgumentError, "invalid or unbounded collision query")

    Enum.reduce_while(shapes, delta, fn %Shape{} = shape, movement ->
      # Native Shapes.collide checks the epsilon before each shape, not after the last.
      if abs(movement) < 1.0e-7,
        do: {:halt, 0.0},
        else: {:cont, Shape.collide(shape, axis, box, movement)}
    end)
  end

  def clip(_, _, _, _), do: raise(ArgumentError, "invalid collision query")

  @doc "Resolve a bounded displacement; supplied colliders must belong to one caller-owned observation."
  def move(box, shapes, {dx, dy, dz} = requested) when is_list(shapes) do
    shapes = Enum.take(shapes, @max_shapes + 1)

    unless length(shapes) <= @max_shapes and Box.valid?(box) and
             Enum.all?(Tuple.to_list(requested), &(is_number(&1) and abs(&1) <= 64.0)),
           do: raise(ArgumentError, "invalid or unbounded movement query")

    requested = {dx * 1.0, dy * 1.0, dz * 1.0}

    if shapes == [] do
      requested
    else
      axes =
        if abs(dx) < abs(dz), do: [{:y, 1}, {:z, 2}, {:x, 0}], else: [{:y, 1}, {:x, 0}, {:z, 2}]

      Enum.reduce(axes, {0.0, 0.0, 0.0}, fn {axis, index}, actual ->
        delta = elem(requested, index)

        if delta == 0.0,
          do: actual,
          else: put_elem(actual, index, clip(axis, Box.move(box, actual), shapes, delta))
      end)
    end
  end

  def move(_, _, _), do: raise(ArgumentError, "invalid movement query")
end
