defmodule Valimc.AI.Goals.RestrictSun do
  @moduledoc """
  `RestrictSunGoal` (VMC-043b: skeletons): by day, a mob with a bare head
  and ground navigation keeps its paths out of the sun
  (`GroundPathNavigation.setAvoidSun`).
  """
  use Valimc.AI.Goal

  def new, do: %{}

  def can_use(state, self) do
    {self.world.bright and self.mob.equipment[:head] == nil and
       self.mind.navigation.kind == :ground, state, self}
  end

  def start(state, self), do: {state, Navigation.avoid_sun(self, true)}

  def stop(state, self) do
    if self.mind.navigation.kind == :ground,
      do: {state, Navigation.avoid_sun(self, false)},
      else: {state, self}
  end
end

defmodule Valimc.AI.Goals.FleeSun do
  @moduledoc """
  `FleeSunGoal` (VMC-043b): by day, a burning mob with no target and a bare
  head under the open sky walks to a random spot within ten blocks out of
  the sky's sight where the light is high enough to keep it off its usual
  walks (`getHidePos`: ten tries).
  """
  use Valimc.AI.Goal
  alias Valimc.AI.RandomPos

  def new(speed), do: %{speed: speed * 1.0, wanted: nil}

  def can_use(state, self) do
    if self.mind.target == nil and self.world.bright and self.mob.living.fire_ticks > 0 and
         World.sees_sky?(self.world, Self.block(self)) and self.mob.equipment[:head] == nil do
      {wanted, self} = hide(self, 10)
      {wanted != nil, %{state | wanted: wanted}, self}
    else
      {false, state, self}
    end
  end

  defp hide(self, 0), do: {nil, self}

  defp hide(self, tries) do
    {x, y, z} = Self.block(self)
    {dx, self} = Self.int(self, 20)
    {dy, self} = Self.int(self, 6)
    {dz, self} = Self.int(self, 20)
    pos = {x + dx - 10, y + dy - 3, z + dz - 10}

    if not World.sees_sky?(self.world, pos) and RandomPos.walk_value(self, pos) < 0.0 do
      {px, py, pz} = pos
      {{px + 0.5, py * 1.0, pz + 0.5}, self}
    else
      hide(self, tries - 1)
    end
  end

  def can_continue(state, self), do: {not Navigation.done?(self.mind.navigation), state, self}

  def start(state, self) do
    {_, self} = Navigation.move_to(self, state.wanted, state.speed)
    {state, self}
  end
end
