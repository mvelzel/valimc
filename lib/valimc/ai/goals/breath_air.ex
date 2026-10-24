defmodule Valimc.AI.Goals.BreathAir do
  @moduledoc """
  `BreathAirGoal`: a mob low on air (under 140) swims up to the first
  block above it (eight up, its column then the four beside it) that gives
  air (no fluid, or a bubble column, and walkable), else eight blocks up,
  looking again each tick, and moves itself once more toward it each tick
  (`moveRelative(0.02, input)` and a move, before its travel: `MobMotion`'s
  `pre_move`). It cannot be interrupted.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Facts

  @bubble_column Valimc.Data.Blocks.id("bubble_column")
  @columns [{0, 0}, {0, -1}, {1, 0}, {0, 1}, {-1, 0}]

  def new, do: %{}

  def can_use(state, self), do: {self.mob.living.air_supply < 140, state, self}

  def interruptable?(_state), do: false

  def start(state, self), do: {state, self |> Navigation.stop() |> find_air()}

  def tick(state, self) do
    self = find_air(self)
    motion = %{self.mob.motion | pre_move: self.yaw * 1.0}
    {state, %{self | mob: %{self.mob | motion: motion}}}
  end

  @doc """
  Where the goal's own move takes the mob, as the rest of its AI reads it
  (navigation and its controls). The owner observes the same native movement
  against its live block/entity colliders; the real tick still moves once.
  """
  def predicted(%Self{mob: %{motion: %{pre_move: yaw}}, world: %{goal_position: preview}} = self)
      when is_float(yaw) and is_function(preview, 1) do
    case preview.(self) do
      {:ok, position} -> position
      _ -> nil
    end
  end

  def predicted(_self), do: nil

  # `findAirPosition`: `BlockPos.neighborColumn` up eight blocks.
  defp find_air(self) do
    {x, y, z} = Self.block(self)

    target =
      Enum.find_value(@columns, fn {dx, dz} ->
        Enum.find_value(y..(y + 8), fn cy ->
          if gives_air?(self.world, {x + dx, cy, z + dz}), do: {x + dx, cy, z + dz}
        end)
      end) || {floor(self.x), floor(self.y + 8.0), floor(self.z)}

    {tx, ty, tz} = target
    {_, self} = Navigation.move_to(self, {tx * 1.0, ty + 1.0, tz * 1.0}, 1.0)
    self
  end

  defp gives_air?(world, pos) do
    case World.block(world, pos) do
      nil ->
        false

      state ->
        (World.fluid(world, pos) == :empty or
           Valimc.Data.Blocks.block_id(state) == @bubble_column) and
          Bitwise.band(:binary.at(Facts.path_flags(), state), 1) != 0
    end
  end
end
