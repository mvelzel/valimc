defmodule Valimc.Physics.ClimbMotion do
  @moduledoc "Native player climbing clamps and post-collision boost; contact is a supplied fact."
  @limit 0.15000000596046448

  def prepare({x, y, z} = velocity, climbing, shift, scaffolding)
      when is_boolean(climbing) and is_boolean(shift) and is_boolean(scaffolding) do
    if valid?(velocity) do
      next =
        if climbing do
          y = max(y, -@limit)

          {max(-@limit, min(@limit, x)),
           if(y < 0 and shift and not scaffolding, do: 0.0, else: y),
           max(-@limit, min(@limit, z))}
        else
          velocity
        end

      {:ok, %{velocity: next, reset_fall: climbing}}
    else
      {:error, :invalid_climb_motion}
    end
  end

  def prepare(_, _, _, _), do: {:error, :invalid_climb_motion}

  def finish({x, y, z} = velocity, climbing, horizontal_collision, jump)
      when is_boolean(climbing) and is_boolean(horizontal_collision) and is_boolean(jump) do
    if valid?(velocity),
      do: {:ok, {x, if(climbing and (horizontal_collision or jump), do: 0.2, else: y), z}},
      else: {:error, :invalid_climb_motion}
  end

  def finish(_, _, _, _), do: {:error, :invalid_climb_motion}

  defp valid?({x, y, z}),
    do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))
end
