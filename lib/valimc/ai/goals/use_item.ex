defmodule Valimc.AI.Goals.UseItem do
  @moduledoc """
  `UseItemGoal` (a wandering trader's drinks, VMC-044a4): when `can_use`
  holds of the mob it takes `stack` in its main hand and uses it
  (`Valimc.AI.Consume` drinks it); once it no longer uses it, its hand is
  emptied and it plays `sound` (at a pitch of 0.9 to 1.1).
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Float32

  def new(stack, sound, can_use), do: %{stack: stack, sound: sound, can_use: can_use}

  def can_use(state, self), do: {state.can_use.(self), state, self}

  def can_continue(state, self), do: {Self.using?(self), state, self}

  def start(state, %Self{mob: mob} = self) do
    self = %{self | mob: %{mob | equipment: Map.put(mob.equipment, :mainhand, state.stack)}}
    {state, Self.start_using(self, :main_hand)}
  end

  def stop(state, %Self{mob: mob} = self) do
    self = %{self | mob: %{mob | equipment: Map.delete(mob.equipment, :mainhand)}}

    if state.sound do
      {f, self} = Self.float(self)
      pitch = Float32.round(Float32.round(f * Float32.round(0.2)) + Float32.round(0.9))
      {state, Self.sound(self, state.sound, 1.0, pitch)}
    else
      {state, self}
    end
  end
end
