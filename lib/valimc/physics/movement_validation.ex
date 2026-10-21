defmodule Valimc.Physics.MovementValidation do
  @moduledoc """
  Vanilla's acceptance of an awake player's move (`handleMovePlayer`): "moved
  wrongly" and the collision rule. The new-collision test itself is the
  physics kernel's (`Kernel.new_collision?/5`).
  """

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

  defp point?(point),
    do: Enum.all?(Tuple.to_list(point), &(is_number(&1) and abs(&1) <= 60_000_000))
end
