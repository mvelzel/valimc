defmodule Valimc.Physics.FluidFlow do
  @moduledoc "A single native fluid current from bounded neighboring observations, without propagation."
  alias Valimc.Physics.{BlockCollisions.Frame, BlockOffset, FluidBoundaries}
  alias Valimc.Registry.BlockFacts
  # Native horizontal iteration order: north, east, south, west.
  @directions [{0, -1, 2}, {1, 0, 5}, {0, 1, 3}, {-1, 0, 4}]

  def sample(%Frame{states: states} = frame, pos)
      when is_map(states) and map_size(states) <= 2048 do
    if BlockOffset.valid_position?(pos) do
      with {:ok, fluid} <- at(frame, pos) do
        if fluid.kind == :empty do
          {:ok, {0.0, 0.0, 0.0}}
        else
          with {:ok, horizontal} <- horizontal(frame, pos, fluid),
               {:ok, falls} <- falling(frame, pos, fluid) do
            {x, _, z} = if falls, do: normalize(horizontal), else: horizontal
            {:ok, normalize({x, if(falls, do: -6.0, else: 0.0), z})}
          end
        end
      end
    else
      {:error, :invalid_fluid_position}
    end
  end

  def sample(_, _), do: {:error, :invalid_fluid_frame}

  defp horizontal(frame, {x, y, z}, fluid) do
    Enum.reduce_while(@directions, {:ok, {0.0, 0.0, 0.0}}, fn {dx, dz, _}, {:ok, {vx, _, vz}} ->
      with {:ok, neighbor} <- at(frame, {x + dx, y, z + dz}),
           {:ok, difference} <- gradient(frame, {x + dx, y, z + dz}, fluid, neighbor) do
        {:cont, {:ok, {vx + f32(dx * difference), 0.0, vz + f32(dz * difference)}}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp gradient(_, _, fluid, neighbor) when neighbor.kind not in [:empty, fluid.kind],
    do: {:ok, 0.0}

  defp gradient(_, _, fluid, %{height: height}) when height > 0,
    do: {:ok, f32(fluid.height - height)}

  defp gradient(frame, {x, y, z} = p, fluid, _) do
    with {:ok, id} <- state(frame, p) do
      if BlockFacts.boundary(id).blocks_flow do
        {:ok, 0.0}
      else
        with {:ok, below} <- at(frame, {x, y - 1, z}) do
          if below.kind in [:empty, fluid.kind] and below.height > 0,
            do: {:ok, f32(fluid.height - f32(below.height - f32(0.8888889)))},
            else: {:ok, 0.0}
        end
      end
    end
  end

  defp falling(_, _, %{falling: false}), do: {:ok, false}

  defp falling(frame, {x, y, z}, fluid) do
    Enum.reduce_while(@directions, {:ok, false}, fn {dx, dz, direction}, _ ->
      with {:ok, side} <- solid(frame, {x + dx, y, z + dz}, fluid, direction),
           {:ok, solid} <-
             if(side,
               do: {:ok, true},
               else: solid(frame, {x + dx, y + 1, z + dz}, fluid, direction)
             ) do
        if solid, do: {:halt, {:ok, true}}, else: {:cont, {:ok, false}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp solid(frame, p, fluid, direction) do
    with {:ok, neighbor} <- at(frame, p),
         {:ok, id} <- state(frame, p) do
      cond do
        neighbor.kind == fluid.kind or BlockFacts.boundary(id).ice -> {:ok, false}
        true -> FluidBoundaries.sturdy?(frame, p, direction)
      end
    end
  end

  defp at(frame, p) do
    with {:ok, id} <- state(frame, p), do: {:ok, BlockFacts.fluid(id)}
  end

  defp state(%Frame{states: states}, p) do
    case Map.fetch(states, p) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :incomplete_fluid_frame}
    end
  end

  def normalize({x, y, z}) do
    length = :math.sqrt(x * x + y * y + z * z)
    if length < 1.0e-5, do: {0.0, 0.0, 0.0}, else: {x / length, y / length, z / length}
  end

  defp f32(value) do
    <<rounded::float-32>> = <<value::float-32>>
    rounded
  end
end
