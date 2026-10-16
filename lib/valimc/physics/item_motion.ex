defmodule Valimc.Physics.ItemMotion do
  @moduledoc "Pure item acceleration and post-collision drag; owners supply contacts and scheduling."
  defstruct fluid: :air, depth: 0.0, on_ground: false, no_gravity: false, refresh: false

  @doc "Request collision work only for moving/airborne items or a supplied support refresh."
  def prepare(velocity, %__MODULE__{} = facts) do
    if vector?(velocity) and valid?(facts) do
      {x, _, z} = next = accelerate(velocity, facts)

      if vector?(next) do
        move = not facts.on_ground or x * x + z * z > f32(0.00001) or facts.refresh
        {:ok, %{velocity: next, request: if(move, do: next)}}
      else
        {:error, :item_motion_limit}
      end
    else
      {:error, :invalid_item_motion}
    end
  end

  def prepare(_, _), do: {:error, :invalid_item_motion}

  @doc "Apply only after movement; collision/block callbacks may have changed velocity and support."
  def finish({x, y, z} = velocity, on_ground, friction)
      when is_boolean(on_ground) and is_number(friction) and friction >= 0 and friction <= 1 do
    if vector?(velocity) do
      air = f32(0.98)
      horizontal = if on_ground, do: f32(air * f32(friction)), else: air
      y = y * air
      y = if on_ground and y < 0, do: y * -0.5, else: y
      {:ok, {x * horizontal, y, z * horizontal}}
    else
      {:error, :invalid_item_motion}
    end
  end

  def finish(_, _, _), do: {:error, :invalid_item_motion}

  defp accelerate({x, y, z}, %{fluid: fluid, depth: depth})
       when fluid in [:water, :lava] and depth > 0.10000000149011612 do
    drag = if fluid == :water, do: f32(0.99), else: f32(0.95)
    rise = if y < f32(0.06), do: f32(0.0005), else: 0.0
    {x * drag, y + rise, z * drag}
  end

  defp accelerate({x, y, z}, %{no_gravity: true}), do: {x * 1.0, y * 1.0, z * 1.0}
  # Entity.applyGravity adds a vector, including positive zero on X/Z.
  defp accelerate({x, y, z}, %{no_gravity: false}), do: {x + 0.0, y - 0.04, z + 0.0}

  defp valid?(f),
    do:
      f.fluid in [:air, :water, :lava] and is_number(f.depth) and f.depth >= 0 and f.depth <= 64 and
        is_boolean(f.on_ground) and is_boolean(f.no_gravity) and is_boolean(f.refresh)

  defp vector?({x, y, z}),
    do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))

  defp vector?(_), do: false

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
