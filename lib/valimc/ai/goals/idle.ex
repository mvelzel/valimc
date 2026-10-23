defmodule Valimc.AI.Goals.Idle do
  @moduledoc """
  A registered goal whose system is not modelled yet and that vanilla could
  not use here without it, so it never runs and draws nothing: a zombie's
  spear attack (`SpearUseGoal`, a main hand without a kinetic weapon) and
  village walk (`MoveThroughVillageGoal`, no villages before VMC-044a).
  `name` is the vanilla goal it stands for.
  """
  use Valimc.AI.Goal

  def new(name), do: %{name: name}

  def can_use(state, self), do: {false, state, self}
end
