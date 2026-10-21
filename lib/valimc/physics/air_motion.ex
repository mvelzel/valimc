defmodule Valimc.Physics.AirMotion do
  @moduledoc "Pure post-collision dry-air velocity update; scheduling and authority stay with owners."
  import Valimc.Physics.Kernel, only: [f32: 1]

  defstruct on_ground: false,
            friction: 0.6,
            friction_modifier: 1.0,
            air_drag_modifier: 1.0,
            gravity: 0.08,
            levitation: nil,
            discard_friction: false,
            omnidirectional: false

  def step({x, y, z}, %__MODULE__{} = facts) do
    if Enum.all?([x, y, z], &bounded?(&1, -60_000_000, 60_000_000)) and valid?(facts) do
      next_y =
        if facts.levitation == nil,
          do: y - facts.gravity,
          else: y + (0.05 * (facts.levitation + 1) - y) * 0.2

      if facts.discard_friction do
        {:ok, {x * 1.0, next_y, z * 1.0}}
      else
        floor =
          if facts.on_ground,
            do: modified(facts.friction, facts.friction_modifier),
            else: 1.0

        air = modified(0.91, facts.air_drag_modifier)
        horizontal = f32(floor * air)

        vertical =
          if facts.omnidirectional, do: air, else: modified(0.98, facts.air_drag_modifier)

        {:ok, {x * horizontal, next_y * vertical, z * horizontal}}
      end
    else
      {:error, :invalid_air_motion}
    end
  end

  def step(_, _), do: {:error, :invalid_air_motion}

  defp valid?(f) do
    is_boolean(f.on_ground) and is_boolean(f.discard_friction) and is_boolean(f.omnidirectional) and
      bounded?(f.friction, 0, 1) and bounded?(f.friction_modifier, 0, 2048) and
      bounded?(f.air_drag_modifier, 0, 2048) and bounded?(f.gravity, -1, 1) and
      (f.levitation == nil or (is_integer(f.levitation) and f.levitation in 0..255))
  end

  defp bounded?(v, low, high), do: is_number(v) and v >= low and v <= high

  defp modified(base, modifier),
    do: f32(1.0 - f32(f32(1.0 - f32(base)) * f32(modifier))) |> max(0.0) |> min(1.0)
end
