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
  (navigation and its controls): its motion past the dead zone plus the
  input at 0.02, without collisions (the kernel makes the real move, from
  where the tick began).
  """
  def predicted(%Self{mob: %{motion: %{pre_move: yaw} = motion}} = self) when is_float(yaw) do
    f = &Valimc.Data.Float32.round/1

    {vx, vy, vz} =
      Enum.map(Tuple.to_list(self.velocity), &if(abs(&1) < 0.003, do: 0.0, else: &1))
      |> List.to_tuple()

    input = {f.(motion.strafe * f.(0.98)), motion.up, f.(motion.forward * f.(0.98))}
    {ix, iy, iz} = input_vector(input, f.(0.02), yaw)
    {self.x + vx + ix, self.y + vy + iy, self.z + vz + iz}
  end

  def predicted(_self), do: nil

  # `Entity.getInputVector` (the kernel's `input_vector`).
  defp input_vector({x, y, z} = input, speed, yaw) do
    length = x * x + y * y + z * z

    if length < 1.0e-7 do
      {0.0, 0.0, 0.0}
    else
      {bx, by, bz} =
        if length > 1.0 do
          l = :math.sqrt(length)
          if l < 1.0e-5, do: {0.0, 0.0, 0.0}, else: {x / l, y / l, z / l}
        else
          input
        end

      {mx, my, mz} = {bx * speed, by * speed, bz * speed}
      f = &Valimc.Data.Float32.round/1
      a = f.(f.(yaw) * f.(0.017453292))
      {sin, cos} = {Valimc.Data.Mth.sin(a), Valimc.Data.Mth.cos(a)}
      {mx * cos - mz * sin, my, mz * cos + mx * sin}
    end
  end

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
