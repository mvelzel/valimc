defmodule Valimc.Blocks.FallingBlock do
  @moduledoc """
  Blocks that fall (VMC-050a2): sand, red sand and gravel
  (`ColoredFallingBlock`), concrete powder, anvils and the dragon egg, as
  vanilla's `FallingBlock` and `FallingBlockEntity` decide.

  - **Fall.** Placed or disturbed, the block checks two ticks later (the
    block rules schedule it, `FallingBlock.onPlace`/`updateShape`); with a
    free cell below (`free?/1`) and inside the world it becomes a falling
    block (`{:fall, position, state}`), leaving its fluid behind. The tick
    effect is the owner's to apply.
  - **Landing.** `landing/4` is what a falling block on the ground (or
    concrete powder in water) does at its cell: it places its block where
    the cell can be replaced and it would not fall on, concrete powder
    hardening when the replaced cell or a side holds water
    (`ConcretePowderBlock.onLand`); otherwise it drops as an item.
  """
  use Valimc.Blocks.Behaviour
  alias Valimc.Data.{BlockFacts, Blocks}

  @powder "ConcretePowderBlock"

  # `read` answers nil outside the region and the build height, so a block
  # on the world's floor stays (`pos.getY() >= level.getMinY()`).
  @impl true
  def scheduled_tick({x, y, z} = position, state, read, _random) do
    case read.({x, y - 1, z}) do
      nil -> []
      below -> if free?(below), do: [{:fall, position, state}], else: []
    end
  end

  @doc """
  `FallingBlock.isFree`: air, fire, a liquid or a replaceable state; a
  falling block falls into it and does not land on it.
  """
  def free?(state),
    do:
      BlockFacts.air?(state) or BlockFacts.flag?(state, :replaceable) or
        BlockFacts.flag?(state, :liquid)

  @doc "Whether `state` is concrete powder."
  def powder?(state), do: Blocks.class(state) == @powder

  @doc "Whether `state` holds water (`FluidState.is(FluidTags.WATER)`)."
  def water?(state), do: BlockFacts.fluid(state).kind == :water

  @doc """
  What a falling block of `block` does on landing in `cell` (its state
  there), with `below` the cell under it and `sides` the states of the cells
  above and beside it (for concrete powder's water): `{:place, state}` or
  `:drop`.
  """
  def landing(block, cell, below, sides) do
    stuck = powder?(block) and water?(cell)
    falls_on = free?(below) and not stuck

    if BlockFacts.flag?(cell, :replaceable) and not falls_on do
      {:place, landed(block, cell, sides)}
    else
      :drop
    end
  end

  # `ConcretePowderBlock.onLand`: concrete where the replaced cell holds
  # water or a side's water touches it (`touchesLiquid`).
  defp landed(block, cell, sides) do
    if powder?(block) and (water?(cell) or Enum.any?(sides, &touches?/1)),
      do: concrete(block),
      else: block
  end

  defp touches?({state, sturdy_toward}), do: water?(state) and not sturdy_toward

  defp concrete(block) do
    name = Blocks.name(Blocks.block_id(block))
    Blocks.default_state(String.replace_suffix(name, "_powder", ""))
  end

  @doc "The state a block falls as: unwaterlogged (`FallingBlockEntity.fall`)."
  def falling_state(state) do
    case Blocks.properties(state) do
      %{"waterlogged" => "true"} ->
        Blocks.state(Blocks.name(Blocks.block_id(state)), %{"waterlogged" => "false"})

      _ ->
        state
    end
  end
end
