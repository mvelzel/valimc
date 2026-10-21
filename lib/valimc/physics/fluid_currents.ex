defmodule Valimc.Physics.FluidCurrents do
  @moduledoc """
  The push of fluid currents on players and items and their water and lava
  depths, through the physics kernel (VMC-077l).
  """
  alias Valimc.Physics.{FluidContact, Kernel}

  def sample(view, box, velocity, pushed \\ true, fast_lava \\ false),
    do: run(view, box, velocity, pushed, fast_lava, :player)

  def sample_item(view, box, velocity, pushed \\ true, fast_lava \\ false),
    do: run(view, box, velocity, pushed, fast_lava, :item)

  defp run(view, box, velocity, pushed, fast_lava, kind) do
    with true <- valid_velocity?(velocity) and is_boolean(pushed) and is_boolean(fast_lava),
         :ok <- FluidContact.bounded(view, box) do
      case Kernel.current(view, box, velocity, pushed, fast_lava, kind) do
        {:ok, nil} ->
          {:error, :invalid_fluid_box}

        {:ok, %{velocity: next} = result} ->
          if valid_velocity?(next), do: {:ok, result}, else: {:error, :fluid_velocity_limit}

        {:error, {:missing_block, _}} ->
          {:error, :incomplete_fluid_frame}

        error ->
          error
      end
    else
      false -> {:error, :invalid_fluid_current}
      error -> error
    end
  end

  defp valid_velocity?({x, y, z}), do: Enum.all?([x, y, z], &(is_number(&1) and abs(&1) <= 64))
  defp valid_velocity?(_), do: false
end
