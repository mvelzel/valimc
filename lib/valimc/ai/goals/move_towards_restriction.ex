defmodule Valimc.AI.Goals.MoveTowardsRestriction do
  @moduledoc """
  `MoveTowardsRestrictionGoal`: a mob outside its home (`Mob.home`) walks
  to a random spot up to 16 blocks toward it (within a quarter turn of its
  way), until its navigation is done.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.RandomPos

  @quarter Valimc.Data.Float32.round(:math.pi() / 2)

  def new(speed), do: %{speed: speed * 1.0, wanted: nil}

  def can_use(state, %Self{mob: %{home: {{hx, hy, hz}, _}}} = self) do
    if RandomPos.within_home?(self, {floor(self.x), floor(self.y), floor(self.z)}) do
      {false, state, self}
    else
      case RandomPos.default_towards(self, 16, 7, {hx + 0.5, hy * 1.0, hz + 0.5}, @quarter) do
        {nil, self} -> {false, state, self}
        {pos, self} -> {true, %{state | wanted: pos}, self}
      end
    end
  end

  def can_use(state, self), do: {false, state, self}

  def can_continue(state, self), do: {not Navigation.done?(self.mind.navigation), state, self}

  def start(state, self) do
    {_, self} = Navigation.move_to(self, state.wanted, state.speed)
    {state, self}
  end
end
