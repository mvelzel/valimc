defmodule Valimc.Physics.FluidContact do
  @moduledoc """
  The fluid a body touches (vanilla's `updateFluidHeightAndDoFluidPushing`
  scan and the eye test), through the physics kernel (VMC-077l).
  """
  alias Valimc.Physics.{Box, Kernel}
  alias Valimc.Registry.BlockFacts
  alias Valimc.World.View
  @inset 0.001
  @max_cells 512

  @doc "The fluid of the block at a position."
  def fluid_at(%View{} = view, pos) do
    case View.fetch(view, pos) do
      {:ok, id} -> {:ok, BlockFacts.fluid(id)}
      :error -> {:error, :incomplete_fluid_frame}
    end
  end

  @doc "The deepest water and lava over the body."
  def sample(view, box) do
    with {:ok, fluids} <- fluids(view, box), do: {:ok, %{water: fluids.water, lava: fluids.lava}}
  end

  @doc "Native eye contact, including source fluid beneath a sturdy downward face."
  def eyes(view, box, eye) do
    with :ok <- bounded(view, box) do
      case Kernel.eyes(view, box, eye) do
        {:ok, nil} -> {:error, :invalid_fluid_box}
        result -> result
      end
    end
  end

  @doc "The touching fluid cells in scan order: `%{position, fluid, depth}`."
  def contacts(view, box) do
    with {:ok, fluids} <- fluids(view, box), do: {:ok, fluids.contacts}
  end

  @doc "Native escape test: any nonempty fluid cell, regardless of its surface height."
  def any_liquid?(view, box) do
    with :ok <- bounded(view, box) do
      case Kernel.any_liquid?(view, box) do
        {:ok, nil} -> {:error, :invalid_fluid_box}
        result -> result
      end
    end
  end

  @doc "The cells the body scan covers, in vanilla's order (oracle coverage checks)."
  def positions(box) do
    with {:ok, {x0, y0, z0, x1, y1, z1}} <- range(box),
         do: {:ok, for(x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z})}
  end

  # The scan's cell range, at most `@max_cells` cells.
  defp range({a, b, c, d, e, f} = box) do
    if Box.valid?(box) and d - a > 2 * @inset and e - b > 2 * @inset and f - c > 2 * @inset do
      {x0, y0, z0} = {floor(a + @inset), floor(b + @inset), floor(c + @inset)}
      {x1, y1, z1} = {ceil(d - @inset) - 1, ceil(e - @inset) - 1, ceil(f - @inset) - 1}

      if (x1 - x0 + 1) * (y1 - y0 + 1) * (z1 - z0 + 1) <= @max_cells,
        do: {:ok, {x0, y0, z0, x1, y1, z1}},
        else: {:error, :fluid_scan_limit}
    else
      {:error, :invalid_fluid_box}
    end
  end

  defp range(_), do: {:error, :invalid_fluid_box}

  @doc false
  # A body scan of at most 512 cells over a view.
  def bounded(%View{}, box), do: with({:ok, _} <- range(box), do: :ok)
  def bounded(_view, _box), do: {:error, :invalid_fluid_frame}

  defp fluids(view, box) do
    with :ok <- bounded(view, box), do: kernel_fluids(view, box)
  end

  defp kernel_fluids(view, box) do
    case Kernel.fluids(view, box) do
      {:ok, nil} -> {:error, :invalid_fluid_box}
      {:ok, fluids} -> {:ok, fluids}
      {:error, {:missing_block, _}} -> {:error, :incomplete_fluid_frame}
      error -> error
    end
  end
end
