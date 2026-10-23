defmodule Valimc.AI.Goals.RandomLookAround do
  @moduledoc "`RandomLookAroundGoal`: by chance (2% an update), a random direction for 20 to 39 ticks."
  use Valimc.AI.Goal

  @chance Valimc.Data.Float32.round(0.02)

  def new, do: %{x: 0.0, z: 0.0, time: 0}

  def can_use(state, self) do
    {f, self} = Self.float(self)
    {f < @chance, state, self}
  end

  def can_continue(state, self), do: {state.time >= 0, state, self}

  def start(state, self) do
    {d, self} = Self.double(self)
    {sin, cos} = Valimc.Native.physics_sin_cos(:math.pi() * 2 * d)
    {n, self} = Self.int(self, 20)
    {%{state | x: cos, z: sin, time: 20 + n}, self}
  end

  def every_tick?(_state), do: true

  def tick(state, self) do
    {%{state | time: state.time - 1},
     Self.look_at(self, {self.x + state.x, Self.eye_y(self), self.z + state.z})}
  end
end
