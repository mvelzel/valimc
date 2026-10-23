defmodule Valimc.AI.Goals.Panic do
  @moduledoc """
  `PanicGoal`: hurt in the last 40 ticks by damage of the `panic_causes`
  tag, it runs to a random target five blocks around until it gets there.
  A burning mob's search for water nearby is VMC-043c's (it runs at random
  meanwhile). With `water` (a turtle's 7) it first runs to the nearest water
  within that many blocks around and one up or down
  (`TurtlePanicGoal.lookForWater`).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.RandomPos
  alias Valimc.Protocol.DamageTypes

  def new(speed, opts \\ []),
    do: %{speed: speed * 1.0, pos: nil, running: false, water: Keyword.get(opts, :water)}

  def can_use(state, self) do
    if panics?(self) do
      case water(state, self) || RandomPos.default(self, 5, 4) do
        {nil, self} -> {false, state, self}
        {pos, self} -> {true, %{state | pos: pos}, self}
      end
    else
      {false, state, self}
    end
  end

  # `lookForWater`: none from inside a block that collides, else the first
  # water by manhattan distance (`findBlocksInBoxByManhattanDistance`).
  defp water(%{water: nil}, _self), do: nil

  defp water(%{water: radius}, self) do
    at = Self.block(self)

    with false <- World.collides?(self.world, at),
         {x, y, z} <-
           Enum.find(
             World.manhattan(at, radius, 1, radius),
             &(World.fluid(self.world, &1) == :water)
           ) do
      {{x * 1.0, y * 1.0, z * 1.0}, self}
    else
      _ -> nil
    end
  end

  # `getLastDamageSource` (40 ticks) of a panicking type.
  defp panics?(%Self{mind: %{damage: {type, tick, _}}} = self),
    do: self.mind.tick - tick <= 40 and DamageTypes.tag?(type, :panic_causes)

  defp panics?(_self), do: false

  def can_continue(state, self), do: {not Navigation.done?(self.mind.navigation), state, self}

  def start(state, self) do
    {_, self} = Navigation.move_to(self, state.pos, state.speed)
    {%{state | running: true}, self}
  end

  def stop(state, self), do: {%{state | running: false}, self}
end
