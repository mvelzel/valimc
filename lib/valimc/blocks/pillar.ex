defmodule Valimc.Blocks.Pillar do
  @moduledoc "Rotated pillars (`RotatedPillarBlock`): the axis follows the clicked face."
  use Valimc.Blocks.Behaviour
  alias Valimc.Blocks.Placement

  # Placement facts order each pillar's states by axis x, y, z.
  @impl true
  def placement(item, _previous, face, _upper, _request) do
    axis =
      cond do
        face < 2 -> 1
        face < 4 -> 2
        true -> 0
      end

    {:ok, elem(Placement.pillar_states(item), axis)}
  end
end
