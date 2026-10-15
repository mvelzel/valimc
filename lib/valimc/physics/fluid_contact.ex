defmodule Valimc.Physics.FluidContact do
  @moduledoc "Bounded fluid depths from the same immutable, fenced frame as player geometry."
  alias Valimc.Physics.{BlockCollisions.Frame, Box, FluidBlocks, FluidBoundaries}
  @inset 0.001
  @max_cells 512

  def fluid_at(%Frame{states: states}, pos) when is_map(states) and map_size(states) <= 2048,
    do: at(states, pos)

  def fluid_at(_, _), do: {:error, :invalid_fluid_frame}

  def sample(frame, box) do
    with {:ok, contacts} <- contacts(frame, box) do
      {:ok,
       Enum.reduce(contacts, %{water: 0.0, lava: 0.0}, fn c, depths ->
         Map.update!(depths, c.fluid.kind, &max(&1, c.depth))
       end)}
    end
  end

  @doc "Native eye contact, including source fluid beneath a sturdy downward face."
  def eyes(frame, box, {x, y, z})
      when is_number(x) and abs(x) <= 30_000_000 and is_number(y) and abs(y) <= 1_000_128 and
             is_number(z) and abs(z) <= 30_000_000 do
    with {:ok, contacts} <- contacts(frame, box) do
      column = {floor(x), floor(z)}

      Enum.reduce_while(contacts, {:ok, %{water: false, lava: false}}, fn
        %{position: {px, py, pz} = pos, fluid: fluid}, {:ok, eyes}
        when {px, pz} == column and y >= py ->
          case camera_height(frame, pos, fluid) do
            {:ok, height} ->
              {:cont, {:ok, Map.update!(eyes, fluid.kind, &(&1 or y <= py + height))}}

            error ->
              {:halt, error}
          end

        _, result ->
          {:cont, result}
      end)
    end
  end

  def eyes(_, _, _), do: {:error, :invalid_fluid_eye}

  @doc "Ordered nonempty contacts for current accumulation; all dependencies retain frame fences."
  def contacts(%Frame{states: states}, box) when is_map(states) and map_size(states) <= 2048 do
    with {:ok, positions} <- positions(box) do
      Enum.reduce_while(positions, {:ok, []}, fn {_, y, _} = p, {:ok, contacts} ->
        with {:ok, fluid} <- at(states, p),
             {:ok, surface} <- surface(states, p, fluid) do
          next =
            if fluid.kind != :empty and y + surface >= elem(box, 1) + @inset,
              do: [%{position: p, fluid: fluid, depth: y + surface - elem(box, 1)} | contacts],
              else: contacts

          {:cont, {:ok, next}}
        else
          error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, contacts} -> {:ok, Enum.reverse(contacts)}
        error -> error
      end
    end
  end

  def contacts(_, _), do: {:error, :invalid_fluid_frame}

  @doc "Native escape test: any nonempty fluid cell, regardless of its surface height."
  def any_liquid?(%Frame{states: states}, box) when is_map(states) and map_size(states) <= 2048 do
    with {:ok, positions} <- positions(box, 0.0) do
      Enum.reduce_while(positions, {:ok, false}, fn p, _ ->
        case at(states, p) do
          {:ok, %{kind: :empty}} -> {:cont, {:ok, false}}
          {:ok, _} -> {:halt, {:ok, true}}
          error -> {:halt, error}
        end
      end)
    end
  end

  def any_liquid?(_, _), do: {:error, :invalid_fluid_frame}

  @doc "Native body scan order, bounded independently of the supplied frame."
  def positions(box), do: positions(box, @inset)

  defp positions(box, inset) do
    if Box.valid?(box) do
      {a, b, c, d, e, f} = box

      if d - a > 2 * inset and e - b > 2 * inset and f - c > 2 * inset do
        {x0, y0, z0} = {floor(a + inset), floor(b + inset), floor(c + inset)}
        {x1, y1, z1} = {ceil(d - inset) - 1, ceil(e - inset) - 1, ceil(f - inset) - 1}

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

  defp camera_height(frame, {x, y, z} = pos, %{source: true} = fluid) do
    with {:ok, sturdy} <- FluidBoundaries.sturdy?(frame, {x, y + 1, z}, 0),
         do: if(sturdy, do: {:ok, 1.0}, else: surface(frame.states, pos, fluid))
  end

  defp camera_height(frame, pos, fluid), do: surface(frame.states, pos, fluid)

  defp at(states, p) do
    case Map.fetch(states, p) do
      {:ok, id} -> FluidBlocks.fetch(id)
      :error -> {:error, :incomplete_fluid_frame}
    end
  end
end
