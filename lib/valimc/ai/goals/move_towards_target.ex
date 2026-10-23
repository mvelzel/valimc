defmodule Valimc.AI.Goals.MoveTowardsTarget do
  @moduledoc """
  `MoveTowardsTargetGoal`: with a target within `within` blocks, a walk to a
  spot 16 blocks toward it (within a quarter turn), kept while the path
  lasts and the target lives and stays that near.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.RandomPos
  alias Valimc.Data.Float32

  def new(speed, within), do: %{speed: speed * 1.0, within: Float32.round(within), wanted: nil}

  def can_use(state, self) do
    case World.target(self) do
      nil ->
        {false, state, self}

      target ->
        if World.distance_sq(self, target) > state.within * state.within do
          {false, state, self}
        else
          radians = Float32.round(:math.pi() / 2)

          case RandomPos.default_towards(self, 16, 7, {target.x, target.y, target.z}, radians) do
            {nil, self} -> {false, state, self}
            {pos, self} -> {true, %{state | wanted: pos}, self}
          end
        end
    end
  end

  def can_continue(state, self) do
    target = World.target(self)

    ok =
      not Navigation.done?(self.mind.navigation) and target != nil and target.alive and
        World.distance_sq(self, target) < state.within * state.within

    {ok, state, self}
  end

  def start(state, self) do
    {_, self} = Navigation.move_to(self, state.wanted, state.speed)
    {state, self}
  end

  def stop(state, self), do: {state, self}
end
