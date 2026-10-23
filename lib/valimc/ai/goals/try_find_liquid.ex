defmodule Valimc.AI.Goals.TryFindLiquid do
  @moduledoc """
  `TryFindLiquidGoal`: a mob on the ground outside water sets its move
  control's wanted position on the first water within two blocks around and
  below it (its move control acts on it only while it navigates).
  """
  use Valimc.AI.Goal
  alias Valimc.Entity.MobMotion

  def new, do: %{}

  def can_use(state, self) do
    {self.on_ground and World.fluid(self.world, Self.block(self)) != :water, state, self}
  end

  def start(state, self) do
    {x0, y0, z0} = {floor(self.x - 2.0), floor(self.y - 2.0), floor(self.z - 2.0)}
    {x1, y1, z1} = {floor(self.x + 2.0), floor(self.y), floor(self.z + 2.0)}

    # `BlockPos.betweenClosed`: x fastest, then y, then z.
    found =
      Enum.find_value(z0..z1, fn z ->
        Enum.find_value(y0..y1, fn y ->
          Enum.find_value(x0..x1, fn x ->
            if World.fluid(self.world, {x, y, z}) == :water, do: {x, y, z}
          end)
        end)
      end)

    case found do
      nil ->
        {state, self}

      {x, y, z} ->
        motion = MobMotion.move_to(self.mob.motion, {x * 1.0, y * 1.0, z * 1.0}, 1.0)
        {state, %{self | mob: %{self.mob | motion: motion}}}
    end
  end
end
