defmodule Valimc.AI.Goals.Panic do
  @moduledoc """
  `PanicGoal`: hurt in the last 40 ticks by damage of the `panic_causes`
  tag, it runs to a random target five blocks around until it gets there.
  A burning mob's search for water nearby is VMC-043c's (it runs at random
  meanwhile).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.RandomPos
  alias Valimc.Protocol.DamageTypes

  def new(speed), do: %{speed: speed * 1.0, pos: nil, running: false}

  def can_use(state, self) do
    if panics?(self) do
      case RandomPos.default(self, 5, 4) do
        {nil, self} -> {false, state, self}
        {pos, self} -> {true, %{state | pos: pos}, self}
      end
    else
      {false, state, self}
    end
  end

  # `getLastDamageSource` (40 ticks) of a panicking type.
  defp panics?(%Self{mind: %{damage: {type, tick}}} = self),
    do: self.mind.tick - tick <= 40 and DamageTypes.tag?(type, :panic_causes)

  defp panics?(_self), do: false

  def can_continue(state, self), do: {not Navigation.done?(self.mind.navigation), state, self}

  def start(state, self) do
    {_, self} = Navigation.move_to(self, state.pos, state.speed)
    {%{state | running: true}, self}
  end

  def stop(state, self), do: {%{state | running: false}, self}
end
