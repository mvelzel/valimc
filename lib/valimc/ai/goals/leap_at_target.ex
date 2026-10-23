defmodule Valimc.AI.Goals.LeapAtTarget do
  @moduledoc """
  `LeapAtTargetGoal` (VMC-043b4: spiders): on the ground, a target two to
  four blocks away is leapt at now and then (one update in three): toward
  it at 0.4 plus a fifth of its motion, `yd` up; it lasts until it lands.
  """
  use Valimc.AI.Goal

  def new(yd), do: %{yd: Valimc.Data.Float32.round(yd), target: nil}

  def can_use(state, self) do
    case World.target(self) do
      nil ->
        {false, state, self}

      target ->
        d = World.distance_sq(self, target)

        cond do
          d < 4.0 or d > 16.0 ->
            {false, state, self}

          not self.on_ground ->
            {false, state, self}

          true ->
            {n, self} = Self.int(self, Mth.reduced(5))
            {n == 0, %{state | target: World.ref(target)}, self}
        end
    end
  end

  def can_continue(state, self), do: {not self.on_ground, state, self}

  def start(state, self) do
    target = World.entity(self.world, state.target)
    {vx, _, vz} = self.velocity
    {dx, dz} = {target.x - self.x, target.z - self.z}

    {x, z} =
      if dx * dx + dz * dz > 1.0e-7 do
        length = :math.sqrt(dx * dx + dz * dz)
        {dx / length * 0.4 + vx * 0.2, dz / length * 0.4 + vz * 0.2}
      else
        {dx, dz}
      end

    {state, %{self | velocity: {x, state.yd * 1.0, z}}}
  end
end
