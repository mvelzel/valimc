defmodule Valimc.Physics.FluidContact do
  @moduledoc "Bounded fluid depths from the same immutable, fenced frame as player geometry."
  alias Valimc.Physics.{BlockCollisions.Frame, Box, FluidBlocks}
  @inset 0.001
  @max_cells 512

  def sample(%Frame{states: states}, box) when is_map(states) and map_size(states) <= 2048 do
    with {:ok, positions} <- positions(box) do
      Enum.reduce_while(positions, {:ok, %{water: 0.0, lava: 0.0}}, fn {_, y, _} = p,
                                                                       {:ok, depths} ->
        with {:ok, fluid} <- at(states, p),
             {:ok, surface} <- surface(states, p, fluid) do
          next =
            if fluid.kind != :empty and y + surface >= elem(box, 1) + @inset,
              do: Map.update!(depths, fluid.kind, &max(&1, y + surface - elem(box, 1))),
              else: depths

          {:cont, {:ok, next}}
        else
          error -> {:halt, error}
        end
      end)
    end
  end

  def sample(_, _), do: {:error, :invalid_fluid_frame}

  @doc "Native body scan order, bounded independently of the supplied frame."
  def positions(box) do
    if Box.valid?(box) do
      {a, b, c, d, e, f} = box

      if d - a > 2 * @inset and e - b > 2 * @inset and f - c > 2 * @inset do
        {x0, y0, z0} = {floor(a + @inset), floor(b + @inset), floor(c + @inset)}
        {x1, y1, z1} = {ceil(d - @inset) - 1, ceil(e - @inset) - 1, ceil(f - @inset) - 1}

        if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) <= @max_cells,
          do: {:ok, for(x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z})},
          else: {:error, :fluid_scan_limit}
      else
        {:error, :invalid_fluid_box}
      end
    else
      {:error, :invalid_fluid_box}
    end
  end

  defp surface(_, _, %{kind: :empty}), do: {:ok, 0.0}

  defp surface(states, {x, y, z}, fluid) do
    with {:ok, above} <- at(states, {x, y + 1, z}),
         do: {:ok, if(above.kind == fluid.kind, do: 1.0, else: fluid.height)}
  end

  defp at(states, p) do
    case Map.fetch(states, p) do
      {:ok, id} -> FluidBlocks.fetch(id)
      :error -> {:error, :incomplete_fluid_frame}
    end
  end
end
