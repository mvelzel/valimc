defmodule Valimc.Physics.StuckMotion do
  @moduledoc "Player slowing contact facts and one-move consumption; owners supply ordered contacts."

  def player_contact(kind, weaving, powder_feet, flying)
      when kind in [:none, :cobweb, :berry_bush, :powder_snow] and is_boolean(weaving) and
             is_boolean(powder_feet) and is_boolean(flying) do
    multiplier =
      case if(flying, do: :none, else: kind) do
        :cobweb when weaving -> {0.5, 0.25, 0.5}
        :cobweb -> {0.25, 0.05000000074505806, 0.25}
        :berry_bush -> {0.800000011920929, 0.75, 0.800000011920929}
        :powder_snow when powder_feet -> {0.8999999761581421, 1.5, 0.8999999761581421}
        _ -> nil
      end

    {:ok, %{multiplier: multiplier, reset_fall: multiplier != nil}}
  end

  def player_contact(_, _, _, _), do: {:error, :invalid_stuck_motion}

  @doc "Native non-piston pre-collision move step; a consumed multiplier clears velocity once."
  def prepare(requested, velocity, {mx, my, mz} = multiplier) do
    if vector?(requested, -64, 64) and vector?(velocity, -64, 64) and vector?(multiplier, 0, 4) do
      if mx * mx + my * my + mz * mz > 1.0e-7 do
        {x, y, z} = requested

        {:ok,
         %{
           requested: {x * mx, y * my, z * mz},
           velocity: {0.0, 0.0, 0.0},
           multiplier: {0.0, 0.0, 0.0}
         }}
      else
        {:ok, %{requested: requested, velocity: velocity, multiplier: multiplier}}
      end
    else
      {:error, :invalid_stuck_motion}
    end
  end

  def prepare(_, _, _), do: {:error, :invalid_stuck_motion}

  defp vector?({x, y, z}, lo, hi),
    do: Enum.all?([x, y, z], &(is_number(&1) and &1 >= lo and &1 <= hi))

  defp vector?(_, _, _), do: false
end
