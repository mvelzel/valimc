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

defmodule Valimc.AI.Goals.RemoveBlock do
  @moduledoc """
  `RemoveBlockGoal`'s search (a zombie's `ZombieAttackTurtleEggGoal`): while
  mobs may grief, every 100 to 199 updates (10 after a find) it looks for its
  block (turtle eggs) with air above within 24 blocks around and three up
  and down, in vanilla's order. Walking to and trampling it is VMC-043b's:
  the goal does not run yet, but its timer and draws are vanilla's.
  """
  use Valimc.AI.Goal

  def new(states), do: %{states: MapSet.new(states), next: 0}

  def can_use(state, self) do
    cond do
      not self.world.mob_griefing ->
        {false, state, self}

      state.next > 0 ->
        {false, %{state | next: state.next - 1}, self}

      found?(state, self) ->
        {false, %{state | next: Mth.reduced(20)}, self}

      true ->
        {n, self} = Self.int(self, 200)
        {false, %{state | next: Mth.reduced(200 + n)}, self}
    end
  end

  # `findNearestBlock` over the blocks the snapshots hold of its kind.
  defp found?(state, self) do
    {x, y, z} = Self.block(self)
    box = {x - 23, y - 4, z - 23, x + 23, y + 2, z + 23}

    self.world
    |> World.find(box, state.states)
    |> Enum.any?(fn {{px, py, pz}, _} ->
      World.air?(self.world, {px, py + 1, pz}) and World.air?(self.world, {px, py + 2, pz})
    end)
  end
end
