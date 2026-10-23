defmodule Valimc.AI.Goals.FollowRidden do
  @moduledoc """
  `FollowPlayerRiddenEntityGoal` (a dolphin following a player's boat):
  boats and other ridden entities are not modelled yet, so none is ever
  near enough to follow; it draws nothing.
  """
  use Valimc.AI.Goal

  def new, do: %{}

  def can_use(state, self), do: {false, state, self}
end
