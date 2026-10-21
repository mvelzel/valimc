defmodule Valimc.Physics.FluidMotion do
  @moduledoc "Pure post-collision water/lava travel and bounded surface-escape intent."
  import Valimc.Physics.Kernel, only: [f32: 1]

  defstruct kind: :water,
            falling: true,
            on_ground: false,
            sprint: false,
            dolphins_grace: false,
            water_efficiency: 0.0,
            gravity: 0.08,
            horizontal_collision: false,
            climbable: false,
            shallow: false,
            old_y: 0.0,
            new_y: 0.0

  def prepare(velocity, %__MODULE__{} = facts) do
    if vector?(velocity) and valid?(facts) do
      next = damp(velocity, facts)
      {x, y, z} = next

      escape =
        if facts.horizontal_collision,
          do: {x, y + 0.6000000238418579 - facts.new_y + facts.old_y, z}

      if escape == nil or vector?(escape),
        do: {:ok, %{velocity: next, escape_query: escape}},
        else: {:error, :fluid_escape_limit}
    else
      {:error, :invalid_fluid_motion}
    end
  end

  def prepare(_, _), do: {:error, :invalid_fluid_motion}

  @doc "Caller resolves the escape against complete collision and fluid observations."
  def finish(%{velocity: {x, _, z}, escape_query: query}, true) when query != nil,
    do: {x, 0.30000001192092896, z}

  def finish(%{velocity: velocity}, free) when is_boolean(free), do: velocity

  defp damp({x, y, z}, %{kind: :water} = f) do
    base = f32(if(f.sprint, do: 0.9, else: 0.8))
    efficiency = f32(f.water_efficiency)
    efficiency = if f.on_ground, do: efficiency, else: f32(efficiency * f32(0.5))

    drag =
      if efficiency > 0,
        do: f32(base + f32(f32(f32(0.54600006) - base) * efficiency)),
        else: base

    drag = if f.dolphins_grace, do: f32(0.96), else: drag
    y = if f.horizontal_collision and f.climbable, do: 0.2, else: y
    {x * drag, falling(y * f32(0.8), f), z * drag}
  end

  defp damp({x, y, z}, %{kind: :lava} = f) do
    y = if f.shallow, do: falling(y * f32(0.8), f), else: y * 0.5
    {x * 0.5, if(f.gravity == 0, do: y, else: y + -f.gravity / 4.0), z * 0.5}
  end

  defp falling(y, %{gravity: gravity, sprint: sprint, falling: descending}) do
    cond do
      gravity == 0 or sprint -> y
      descending and abs(y - 0.005) >= 0.003 and abs(y - gravity / 16.0) < 0.003 -> -0.003
      true -> y - gravity / 16.0
    end
  end

  defp valid?(f) do
    f.kind in [:water, :lava] and
      Enum.all?(
        [
          f.falling,
          f.on_ground,
          f.sprint,
          f.dolphins_grace,
          f.horizontal_collision,
          f.climbable,
          f.shallow
        ],
        &is_boolean/1
      ) and bounded?(f.water_efficiency, 0, 1) and bounded?(f.gravity, -1, 1) and
      bounded?(f.old_y, -60_000_000, 60_000_000) and bounded?(f.new_y, -60_000_000, 60_000_000) and
      abs(f.new_y - f.old_y) <= 64
  end

  defp vector?({x, y, z}), do: Enum.all?([x, y, z], &bounded?(&1, -64, 64))
  defp vector?(_), do: false
  defp bounded?(v, low, high), do: is_number(v) and v >= low and v <= high
end
