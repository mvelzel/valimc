defmodule Valimc.Physics.RelativeMotion do
  @moduledoc "Native relative-input math; callers own intent, attributes and simulation admission."
  import Bitwise
  @sin_scale 10_430.378350470453

  defstruct on_ground: false,
            friction: 0.6,
            movement_speed: 0.1,
            flying: false,
            sprint: false,
            flying_speed: 0.05,
            water_efficiency: 0.0

  def vector({x, y, z}, speed, yaw)
      when is_number(x) and abs(x) <= 64 and is_number(y) and abs(y) <= 64 and
             is_number(z) and abs(z) <= 64 and is_number(speed) and speed >= 0 and speed <= 64 and
             is_number(yaw) and abs(yaw) <= 1_000_000 do
    length2 = x * x + y * y + z * z

    if length2 < 1.0e-7 do
      {:ok, {0.0, 0.0, 0.0}}
    else
      {x, y, z} =
        if length2 > 1.0 do
          length = :math.sqrt(length2)
          {x / length, y / length, z / length}
        else
          {x, y, z}
        end

      speed = f32(speed)
      {x, y, z} = {x * speed, y * speed, z * speed}
      angle = f32(f32(yaw) * f32(0.017453292))
      sin = trig(trunc(angle * @sin_scale))
      cos = trig(trunc(angle * @sin_scale + 16_384.0))
      {:ok, {x * cos - z * sin, y, z * cos + x * sin}}
    end
  end

  def vector(_, _, _), do: {:error, :invalid_relative_motion}

  def accelerate({x, y, z}, input, speed, yaw)
      when is_number(x) and abs(x) <= 64 and is_number(y) and abs(y) <= 64 and
             is_number(z) and abs(z) <= 64 do
    with {:ok, {dx, dy, dz}} <- vector(input, speed, yaw), do: {:ok, {x + dx, y + dy, z + dz}}
  end

  def accelerate(_, _, _, _), do: {:error, :invalid_relative_motion}

  @doc "Friction is the already modified native floor coefficient; attributes are supplied."
  def speed(kind, %__MODULE__{} = facts) when kind in [:air, :water, :lava] do
    if valid?(facts),
      do: {:ok, rate(kind, facts)},
      else: {:error, :invalid_relative_motion}
  end

  def speed(_, _), do: {:error, :invalid_relative_motion}

  defp rate(:air, %{on_ground: true} = f) do
    friction = f32(f.friction)
    speed = f32(f.movement_speed)

    if friction > 0.6,
      do: f32(speed * f32(f32(0.21600002) / f32(f32(friction * friction) * friction))),
      else: speed
  end

  defp rate(:air, %{flying: true} = f),
    do: f32(f32(f.flying_speed) * if(f.sprint, do: 2, else: 1))

  defp rate(:air, f), do: f32(if(f.sprint, do: 0.025999999, else: 0.02))

  defp rate(:water, f) do
    efficiency = f32(f.water_efficiency)
    efficiency = if f.on_ground, do: efficiency, else: f32(efficiency * f32(0.5))
    base = f32(0.02)

    if efficiency > 0,
      do: f32(base + f32(f32(f32(f.movement_speed) - base) * efficiency)),
      else: base
  end

  defp rate(:lava, _), do: f32(0.02)

  defp valid?(f),
    do:
      is_boolean(f.on_ground) and is_boolean(f.flying) and is_boolean(f.sprint) and
        bounded?(f.friction, 0, 1) and bounded?(f.movement_speed, 0, 64) and
        bounded?(f.flying_speed, 0, 64) and bounded?(f.water_efficiency, 0, 1)

  defp bounded?(v, lo, hi), do: is_number(v) and v >= lo and v <= hi
  defp trig(index), do: f32(:math.sin((index &&& 65_535) / @sin_scale))

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
