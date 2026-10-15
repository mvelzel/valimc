defmodule Valimc.Physics.MovementValidation do
  @moduledoc "Pure awake-player post-move acceptance; sampling, speed and ownership are separate."
  alias Valimc.Physics.{Box, Shape, VoxelOps}
  @epsilon 9.999999747378752e-6

  def wrongly?({x, _y, z} = requested, {mx, _my, mz} = moved, mode, changing, impulse)
      when mode in [:survival, :creative, :adventure, :spectator] and is_boolean(changing) and
             is_boolean(impulse) do
    if point?(requested) and point?(moved) do
      # The pinned packet handler suppresses the vertical residual. Movement
      # clipping and newly entered geometry still enforce vertical obstacles.
      {:ok,
       not (changing or impulse or mode in [:creative, :spectator]) and
         (x - mx) * (x - mx) + (z - mz) * (z - mz) > 0.0625}
    else
      {:error, :invalid_movement_observation}
    end
  end

  def wrongly?(_, _, _, _, _), do: {:error, :invalid_movement_observation}

  def collision_rejected?(no_physics, wrongly, old_clear, new_collision)
      when is_boolean(no_physics) and is_boolean(wrongly) and is_boolean(old_clear) and
             is_boolean(new_collision),
      do: {:ok, not no_physics and ((wrongly and old_clear) or new_collision)}

  def collision_rejected?(_, _, _, _), do: {:error, :invalid_movement_observation}

  @doc "Colliders must already come from the deflated target body's complete native query."
  def new_collision?(old_box, supplied) when is_list(supplied) do
    shapes = Enum.take(supplied, 129)

    if Box.valid?(old_box) and length(shapes) <= 128 and
         Enum.all?(shapes, &match?(%Shape{}, &1)) do
      {x0, y0, z0, x1, y1, z1} = old_box

      previous =
        VoxelOps.world_box(
          Box.new(
            {x0 + @epsilon, y0 + @epsilon, z0 + @epsilon, x1 - @epsilon, y1 - @epsilon,
             z1 - @epsilon}
          )
        )

      {:ok, Enum.any?(shapes, &(not VoxelOps.intersects?(&1, previous)))}
    else
      {:error, :invalid_movement_observation}
    end
  rescue
    _ in [ArgumentError, FunctionClauseError] -> {:error, :invalid_movement_observation}
  end

  def new_collision?(_, _), do: {:error, :invalid_movement_observation}

  defp point?(point),
    do: Enum.all?(Tuple.to_list(point), &(is_number(&1) and abs(&1) <= 60_000_000))
end
