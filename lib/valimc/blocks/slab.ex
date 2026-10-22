defmodule Valimc.Blocks.Slab do
  @moduledoc "Slabs: top/bottom by hit face and height, waterlogged over source water, doubling."
  use Valimc.Blocks.Behaviour
  alias Valimc.Blocks.Placement
  alias Valimc.Data.BlockFacts

  # Placement facts order each slab's states top/bottom × waterlogged, then double.
  @impl true
  def placement(item, previous, face, upper, _request) do
    states = Placement.slab_states(item)

    case Placement.slab_half(previous) do
      {^item, _} ->
        {:ok, elem(states, 5)}

      _ ->
        fluid = BlockFacts.fluid(previous)
        top = face == 0 or (face >= 2 and upper)

        index =
          if(top, do: 0, else: 2) + if(fluid.kind == :water and fluid.source, do: 0, else: 1)

        {:ok, elem(states, index)}
    end
  end

  @doc "A single slab yields to the same slab placed into its empty half; a double never does."
  @impl true
  def replaceable?(state, item, face, upper, clicked) do
    {slab_item, half} = Placement.slab_half(state)

    slab_item == item and half != 2 and
      (not clicked or (half == 1 and (face == 1 or (face >= 2 and upper))) or
         (half == 0 and (face == 0 or (face >= 2 and not upper))))
  end
end
