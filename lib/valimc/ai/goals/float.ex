defmodule Valimc.AI.Goals.Float do
  @moduledoc "`FloatGoal`: in water deeper than its jump threshold, or in lava, it jumps (80%)."
  use Valimc.AI.Goal

  @chance Valimc.Data.Float32.round(0.8)

  def can_use(state, self) do
    deep = self.mob.motion.water > Self.jump_threshold(self) or Self.in_lava?(self)
    {deep, state, self}
  end

  def every_tick?(_state), do: true

  def tick(state, self) do
    {f, self} = Self.float(self)
    {state, if(f < @chance, do: Self.jump(self), else: self)}
  end
end
