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
end
