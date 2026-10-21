defmodule Valimc.Physics.OrbMotion do
  @moduledoc """
  An experience orb's launch (vanilla `ExperienceOrb` spawned by a block):
  its position and velocity from three supplied uniform draws. Orbs do not
  move after launch yet (VMC-077l defers their tick to the physics kernel).
  """

  @doc "Three supplied native uniform double draws; spawn escape and cosmetic yaw are separate."
  def launch(position, direction, {a, b, c} = draws) do
    if Valimc.World.Items.valid_position?(position) and vector?(direction, 64) and
         Enum.all?(Tuple.to_list(draws), &(is_float(&1) and &1 >= 0 and &1 < 1)) do
      velocity = {(a * 0.2 - 0.1) * 2.0, b * 0.2 * 2.0, (c * 0.2 - 0.1) * 2.0}

      velocity =
        if dot(direction, direction) > 0 and dot(direction, velocity) < 0,
          do: scale(velocity, -1.0),
          else: velocity

      at = add(position, scale(normalize(direction), 0.25))

      if Valimc.World.Items.valid_position?(at),
        do: {:ok, %{position: at, velocity: velocity}},
        else: {:error, :orb_motion_limit}
    else
      invalid()
    end
  end

  def launch(_, _, _), do: invalid()

  defp normalize(v) do
    length = :math.sqrt(dot(v, v))
    # f32(1.0e-5)
    if length < 9.999999747378752e-6, do: {0.0, 0.0, 0.0}, else: divide(v, length)
  end

  defp vector?({x, y, z}, bound), do: Enum.all?([x, y, z], &bounded?(&1, bound))
  defp vector?(_, _), do: false
  defp bounded?(n, bound), do: is_number(n) and abs(n) <= bound
  defp dot({x, y, z}, {a, b, c}), do: x * a + y * b + z * c
  defp scale({x, y, z}, n), do: {x * n, y * n, z * n}
  defp divide({x, y, z}, n), do: {x / n, y / n, z / n}
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
  defp invalid, do: {:error, :invalid_orb_motion}
end
