defmodule Valimc.Living.Landing do
  @moduledoc """
  Landing damage (vanilla `Block.fallOn`): the call a landing on a block makes.
  The physics kernel finds the landing block and distance (VMC-077l2); only
  the player owner applies the damage.
  """
  alias Valimc.Data.BlockFacts

  @doc "Native `fallOn`: the damage call landing on `state` from `distance` makes, or nil."
  def call(state, distance, shift) do
    rule = state |> BlockFacts.landing() |> elem(if(shift, do: 1, else: 0))

    {:ok,
     if rule do
       %{
         distance: distance * rule.distance_scale + rule.distance_offset,
         multiplier: rule.multiplier,
         source: rule.source
       }
     end}
  end

  @doc "Whether a support at `state` keeps the legacy support height (walls, fence gates, fences)."
  def holds_y?(state),
    do: BlockFacts.motion(state).support_holds_y or BlockFacts.flag?(state, :fence)
end
