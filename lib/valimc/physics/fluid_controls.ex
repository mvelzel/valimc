defmodule Valimc.Physics.FluidControls do
  @moduledoc "Native vertical fluid intent around player normalization; ground jumps remain explicit."
  defstruct water: 0.0,
            lava: 0.0,
            threshold: 0.4,
            on_ground: false,
            jump: false,
            shift: false,
            flying: false

  @push 0.03999999910593033

  def step({x, y, z} = velocity, %__MODULE__{} = f) do
    if valid_velocity?(velocity) and valid?(f) do
      y = if f.water > 0 and f.shift and not f.flying, do: y - @push, else: y
      {x, y, z} = Valimc.PlayerKinetics.normalize({x, y, z})
      depth = if f.lava > 0, do: f.lava, else: f.water

      action =
        cond do
          not f.jump or f.flying -> :none
          f.water > 0 and depth > 0 and (not f.on_ground or depth > f.threshold) -> :float
          f.lava > 0 and (not f.on_ground or f.lava > f.threshold) -> :float
          f.on_ground or (f.water > 0 and depth <= f.threshold) -> :ground
          true -> :none
        end

      next = {x, if(action == :float, do: y + @push, else: y), z}

      if valid_velocity?(next),
        do: {:ok, %{velocity: next, ground_jump: action == :ground}},
        else: {:error, :fluid_input_limit}
    else
      {:error, :invalid_fluid_controls}
    end
  end

  def step(_, _), do: {:error, :invalid_fluid_controls}

  defp valid?(f),
    do:
      Enum.all?([f.on_ground, f.jump, f.shift, f.flying], &is_boolean/1) and
        bounded?(f.water, 0, 32) and bounded?(f.lava, 0, 32) and bounded?(f.threshold, 0, 0.4)

  defp valid_velocity?({x, y, z}), do: Enum.all?([x, y, z], &bounded?(&1, -64, 64))
  defp bounded?(v, lo, hi), do: is_number(v) and v >= lo and v <= hi
end
