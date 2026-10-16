defmodule Valimc.Physics.ItemDrop do
  @moduledoc "Pure native launch from accepted pose and supplied random draws; no item ownership."
  import Bitwise
  @sin_scale 10_430.378350470453
  @max_random 0.9999999403953552

  def launch(%{x: x, y: y, z: z, yaw: yaw, pitch: pitch}, eye, kind, [r0, r1, r2, r3])
      when is_number(x) and abs(x) <= 29_999_984 and is_number(y) and abs(y) <= 1_000_000 and
             is_number(z) and abs(z) <= 29_999_984 and is_number(yaw) and abs(yaw) <= 1_000_000 and
             is_number(pitch) and abs(pitch) <= 1_000_000 and is_number(eye) and eye >= 0 and
             eye <= 8 and
             kind in [:directed, :scattered] do
    draws = [r0, r1, r2, r3]
    height = y + f32(eye) - f32(0.3)

    if abs(height) <= 1_000_000 and
         Enum.all?(draws, &(is_number(&1) and &1 >= 0 and &1 <= @max_random)) do
      {:ok,
       %{
         position: {x * 1.0, height, z * 1.0},
         velocity: velocity(kind, yaw, pitch, Enum.map(draws, &f32/1)),
         pickup_delay: 40
       }}
    else
      {:error, :invalid_item_launch}
    end
  end

  def launch(_, _, _, _), do: {:error, :invalid_item_launch}

  defp velocity(:scattered, _, _, [radius, angle | _]) do
    radius = f32(radius * f32(0.5))
    angle = f32(angle * f32(6.2831855))
    {f32(-sine(angle) * radius), f32(0.2), f32(cosine(angle) * radius)}
  end

  defp velocity(:directed, yaw, pitch, [angle, radius, up, down]) do
    yaw = f32(f32(yaw) * f32(0.017453292))
    pitch = f32(f32(pitch) * f32(0.017453292))
    sin_yaw = sine(yaw)
    cos_yaw = cosine(yaw)
    sin_pitch = sine(pitch)
    cos_pitch = cosine(pitch)
    angle = f32(angle * f32(6.2831855))
    radius = f32(f32(0.02) * radius)
    x = f32(f32(-sin_yaw * cos_pitch) * f32(0.3))
    z = f32(f32(cos_yaw * cos_pitch) * f32(0.3))
    y = f32(f32(-sin_pitch * f32(0.3)) + f32(0.1))
    y = f32(y + f32(f32(up - down) * f32(0.1)))
    {x + :math.cos(angle) * radius, y, z + :math.sin(angle) * radius}
  end

  defp sine(angle), do: trig(trunc(angle * @sin_scale))
  defp cosine(angle), do: trig(trunc(angle * @sin_scale + 16_384.0))
  defp trig(index), do: f32(:math.sin((index &&& 65_535) / @sin_scale))

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
