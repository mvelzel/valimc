defmodule Valimc.Physics.CollisionResponse do
  @moduledoc "Pure collision velocity restitution; the owner applies returned bounce effects."
  defstruct x_collision: false,
            z_collision: false,
            vertical_collision: false,
            below: false,
            suppress_bounce: false,
            block_suppresses_bounce: false,
            entity_bounciness: 0.0,
            block_bounciness: 0.0,
            gravity: 0.08,
            air_drag: 0.98

  def step({x, y, z} = velocity, moved_y, %__MODULE__{} = f) do
    if vector?(velocity) and bounded?(moved_y, -60_000_000, 60_000_000) and valid?(f) do
      {x, y, z} = {x * 1.0, y * 1.0, z * 1.0}
      entity = if f.suppress_bounce, do: 0.0, else: f.entity_bounciness * 1.0
      next_x = if f.x_collision, do: -x * entity, else: x
      next_z = if f.z_collision, do: -z * entity, else: z
      horizontal_bounce = entity > 0 and (f.x_collision or f.z_collision)

      bounce =
        cond do
          not f.below -> entity
          -y <= f.gravity or f.suppress_bounce or f.block_suppresses_bounce -> 0.0
          true -> max(entity, f32(f.block_bounciness))
        end

      bounced = horizontal_bounce or (f.vertical_collision and bounce > 0)

      try do
        next_y =
          cond do
            not f.vertical_collision ->
              y

            bounce > 0 ->
              fraction = moved_y / y
              gravity = fraction * f.gravity
              drag = 1.0 + fraction * (f32(f.air_drag) - 1.0)
              (gravity - y) * drag * bounce

            true ->
              (0.0 - y) * 1.0 * bounce
          end

        result = {next_x, next_y, next_z}
        if vector?(result), do: {:ok, %{velocity: result, bounced: bounced}}, else: invalid()
      rescue
        # Entity.setDeltaMovement ignores an entire nonfinite candidate; the
        # bounce notification was already emitted before its finite guard.
        ArithmeticError -> {:ok, %{velocity: {x, y, z}, bounced: bounced}}
      end
    else
      invalid()
    end
  end

  def step(_, _, _), do: invalid()

  defp valid?(f) do
    Enum.all?(
      [
        f.x_collision,
        f.z_collision,
        f.vertical_collision,
        f.below,
        f.suppress_bounce,
        f.block_suppresses_bounce
      ],
      &is_boolean/1
    ) and (not f.below or f.vertical_collision) and
      bounded?(f.entity_bounciness, 0, 1) and bounded?(f.block_bounciness, 0, 1) and
      bounded?(f.gravity, -1, 1) and bounded?(f.air_drag, 0, 1)
  end

  defp vector?({x, y, z}),
    do: Enum.all?([x, y, z], &bounded?(&1, -60_000_000, 60_000_000))

  defp bounded?(v, low, high), do: is_number(v) and v >= low and v <= high
  defp invalid, do: {:error, :invalid_collision_response}

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
