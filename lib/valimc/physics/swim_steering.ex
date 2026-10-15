defmodule Valimc.Physics.SwimSteering do
  @moduledoc "Native pre-travel swimming pitch blend; contact/state are supplied observations."
  import Bitwise
  @sin_scale 10_430.378350470453

  def look_y(pitch) when is_number(pitch) and abs(pitch) <= 1_000_000 do
    angle = f32(f32(pitch) * f32(0.017453292))
    {:ok, -f32(:math.sin((trunc(angle * @sin_scale) &&& 65_535) / @sin_scale))}
  end

  def look_y(_), do: {:error, :invalid_swim_pitch}

  def step({x, y, z}, look_y, swimming, jump, above_fluid, passenger)
      when is_number(x) and abs(x) <= 64 and is_number(y) and abs(y) <= 64 and
             is_number(z) and abs(z) <= 64 and is_number(look_y) and abs(look_y) <= 1 and
             is_boolean(swimming) and is_boolean(jump) and is_boolean(above_fluid) and
             is_boolean(passenger) do
    y =
      if swimming and not passenger and (look_y <= 0 or jump or above_fluid),
        do: y + (look_y - y) * if(look_y < -0.2, do: 0.085, else: 0.06),
        else: y

    {:ok, {x * 1.0, y * 1.0, z * 1.0}}
  end

  def step(_, _, _, _, _, _), do: {:error, :invalid_swim_steering}

  defp f32(n) do
    <<rounded::float-32>> = <<n::float-32>>
    rounded
  end
end
