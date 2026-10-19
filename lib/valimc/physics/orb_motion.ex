defmodule Valimc.Physics.OrbMotion do
  @moduledoc "Pure XP orb arithmetic with supplied contacts, target and collision facts; no live ownership."
  defstruct eye_water: false,
            embedded: false,
            no_gravity: false,
            lava_draws: nil,
            target: nil,
            on_ground: false,
            below: false,
            friction: 0.6

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

  @doc "Acceleration before movement. Escape and current sampling belong to the caller."
  def prepare(velocity, %__MODULE__{} = facts) do
    if vector?(velocity, 64) and valid?(facts) do
      next = velocity |> accelerate(facts) |> lava(facts.lava_draws) |> attract(facts.target)
      if vector?(next, 64), do: {:ok, next}, else: {:error, :orb_motion_limit}
    else
      invalid()
    end
  end

  def prepare(_, _), do: invalid()

  @doc "Post-movement friction scales every axis; landing bounce uses Y captured before movement."
  def finish(velocity, incoming_y, %__MODULE__{} = facts) do
    if vector?(velocity, 64) and bounded?(incoming_y, 64) and valid?(facts) do
      drag = if facts.on_ground, do: f32(f32(0.98) * f32(facts.friction)), else: f32(0.98)
      {x, y, z} = scale(velocity, drag)
      gravity = if facts.no_gravity, do: 0.0, else: 0.03
      y = if facts.below and incoming_y < -gravity, do: -incoming_y * 0.4, else: y
      {:ok, {x, y, z}}
    else
      invalid()
    end
  end

  def finish(_, _, _), do: invalid()

  @doc "Return a terminal expiry decision; its owning storage protocol must persist it before removal."
  def tick_age(age) when is_integer(age) and age in -32_768..5999,
    do: {:ok, %{age: age + 1, expired: age + 1 >= 6000}}

  def tick_age(_), do: invalid()

  defp accelerate({x, y, z}, %{eye_water: true}),
    do: {x * f32(0.99), min(y + f32(0.0005), f32(0.06)), z * f32(0.99)}

  defp accelerate(v, %{embedded: true}), do: scale(v, 1.0)
  defp accelerate(v, %{no_gravity: true}), do: scale(v, 1.0)
  defp accelerate(v, _), do: add(v, {0.0, -0.03, 0.0})

  defp lava(v, nil), do: v

  defp lava(_, {a, b, c, d}),
    do:
      {f32(f32((a - b) / 16_777_216) * f32(0.2)), f32(0.2),
       f32(f32((c - d) / 16_777_216) * f32(0.2))}

  defp attract(v, nil), do: v

  defp attract(v, offset) do
    weight = 1.0 - :math.sqrt(dot(offset, offset)) / 8.0
    add(v, scale(normalize(offset), weight * weight * 0.1))
  end

  defp normalize(v) do
    length = :math.sqrt(dot(v, v))
    if length < f32(1.0e-5), do: {0.0, 0.0, 0.0}, else: divide(v, length)
  end

  defp valid?(f),
    do:
      Enum.all?([f.eye_water, f.embedded, f.no_gravity, f.on_ground, f.below], &is_boolean/1) and
        is_number(f.friction) and f.friction >= 0 and f.friction <= 1 and
        (f.target == nil or vector?(f.target, 16)) and draws?(f.lava_draws)

  defp draws?(nil), do: true

  defp draws?({a, b, c, d}),
    do: Enum.all?([a, b, c, d], &(is_integer(&1) and &1 in 0..16_777_215))

  defp draws?(_), do: false
  defp vector?({x, y, z}, bound), do: Enum.all?([x, y, z], &bounded?(&1, bound))
  defp vector?(_, _), do: false
  defp bounded?(n, bound), do: is_number(n) and abs(n) <= bound
  defp dot({x, y, z}, {a, b, c}), do: x * a + y * b + z * c
  defp scale({x, y, z}, n), do: {x * n, y * n, z * n}
  defp divide({x, y, z}, n), do: {x / n, y / n, z / n}
  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
  defp invalid, do: {:error, :invalid_orb_motion}

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
