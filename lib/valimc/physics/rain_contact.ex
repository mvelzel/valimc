defmodule Valimc.Physics.RainContact do
  @moduledoc "Native two-point rain eligibility from observed sky, motion-blocking height and biome precipitation."
  defguardp point(y, sky, precipitation)
            when is_integer(y) and y in -1_000_000..1_000_000 and is_boolean(sky) and
                   precipitation in [:none, :rain, :snow]

  def exposed?(wet, surface, {fy, fs, fp} = feet, {hy, hs, hp} = head)
      when is_boolean(wet) and is_integer(surface) and surface in -64..320 and
             point(fy, fs, fp) and point(hy, hs, hp) and (hy - fy) in 0..2 do
    if fy == hy and feet != head do
      {:error, :inconsistent_rain_observation}
    else
      {:ok, wet and (rain?(surface, feet) or rain?(surface, head))}
    end
  end

  def exposed?(_, _, _, _), do: {:error, :invalid_rain_observation}

  defp rain?(surface, {y, sky, precipitation}),
    do: sky and surface <= y and precipitation == :rain
end
