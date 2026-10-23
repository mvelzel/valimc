defmodule Valimc.AI.Goals.RemoveBlock do
  @moduledoc """
  `RemoveBlockGoal` as the zombie family's `ZombieAttackTurtleEggGoal`
  (VMC-043b2): while mobs may grief, every 100 to 199 updates (10 after a
  find) it looks for its block (turtle eggs) with two blocks of air above
  within 24 blocks around and three up and down, nearest first in
  vanilla's order (`MoveToBlockGoal.findNearestBlock`), and walks to stand
  on it (`Goals.MoveToBlock`). There, with an egg at or around its feet, it
  stamps: up a little and down every other tick with the egg crunching
  every sixth, and after three seconds the eggs are gone (`{:remove_block,
  cell}`) with their breaking sound. Stopping, it lands as if from a block.
  """
  use Valimc.AI.Goal
  alias Valimc.AI.Goals.MoveToBlock
  alias Valimc.Data.Float32

  def new(states) do
    states = MapSet.new(states)

    # `ZombieAttackTurtleEggGoal.acceptedDistance`: 1.14.
    MoveToBlock.new(1.0, 24, &valid?(states, &1, &2, &3), vertical: 3, accepted: 1.14)
    |> Map.merge(%{states: states, since: 0})
  end

  @doc """
  A turtle egg block after one egg cracks (`TurtleEggBlock.decreaseEggs`):
  one egg fewer, or the block's fluid for the last.
  """
  def cracked(state) do
    properties = Map.new(Valimc.Data.Blocks.properties(state))

    case Integer.parse(Map.get(properties, "eggs", "1")) do
      {n, ""} when n > 1 ->
        Valimc.Data.Blocks.state("turtle_egg", %{properties | "eggs" => Integer.to_string(n - 1)})

      _ ->
        Valimc.Data.BlockFacts.fluid_remains(state)
    end
  end

  defp valid?(states, self, {x, y, z} = cell, state) do
    {egg?(states, self.world, cell) and World.air?(self.world, {x, y + 1, z}) and
       World.air?(self.world, {x, y + 2, z}), state}
  end

  defp egg?(states, world, cell), do: MapSet.member?(states, World.block(world, cell))

  def every_tick?(_state), do: true

  def can_use(state, self) do
    cond do
      not self.world.mob_griefing ->
        {false, state, self}

      state.next > 0 ->
        {false, %{state | next: state.next - 1}, self}

      true ->
        case nearest(state, self) do
          nil ->
            {n, self} = Self.int(self, 200)
            {false, %{state | next: Mth.reduced(200 + n)}, self}

          cell ->
            {true, %{state | next: Mth.reduced(20), cell: cell}, self}
        end
    end
  end

  # `findNearestBlock` over the blocks the snapshots hold of its kind: the
  # valid one first in the search's order (layers 0, 1, -1, ... below its
  # feet, then rings outward, then the spiral within a ring).
  defp nearest(state, self) do
    {bx, by, bz} = Self.block(self)
    r = state.range

    box =
      {bx - (r - 1), by - 1 - state.vertical, bz - (r - 1), bx + r - 1, by - 1 + state.vertical,
       bz + r - 1}

    self.world
    |> World.find(box, state.states)
    |> Enum.map(&elem(&1, 0))
    |> Enum.filter(fn cell ->
      Valimc.AI.RandomPos.within_home?(self, cell) and
        elem(valid?(state.states, self, cell, state), 0)
    end)
    |> Enum.min_by(fn {x, y, z} -> order({x - bx, y - (by - 1), z - bz}) end, fn -> nil end)
  end

  defp order({dx, dy, dz}) do
    ring = max(abs(dx), abs(dz))
    z = if abs(dx) < ring, do: if(dz == ring, do: 0, else: 1), else: spiral(dz)
    {spiral(dy), ring, spiral(dx), z}
  end

  # The index in 0, 1, -1, 2, -2, ...
  defp spiral(0), do: 0
  defp spiral(v) when v > 0, do: 2 * v - 1
  defp spiral(v), do: -2 * v

  def can_continue(state, self), do: MoveToBlock.can_continue(state, self)

  def start(state, self) do
    {state, self} = MoveToBlock.start(state, self)
    {%{state | since: 0}, self}
  end

  def stop(state, self),
    do: {state, %{self | mob: %{self.mob | motion: %{self.mob.motion | fall_distance: 1.0}}}}

  def tick(state, self) do
    {state, self} = MoveToBlock.tick(state, self)

    case at_feet(state, self) do
      cell when cell != nil and state.reached -> stamp(state, self, cell)
      _ -> {state, self}
    end
  end

  # `getPosWithBlock`: its own block, below, west, east, north, south, two below.
  defp at_feet(state, self) do
    {x, y, z} = Self.block(self)

    Enum.find(
      [
        {x, y, z},
        {x, y - 1, z},
        {x - 1, y, z},
        {x + 1, y, z},
        {x, y, z - 1},
        {x, y, z + 1},
        {x, y - 2, z}
      ],
      &egg?(state.states, self.world, &1)
    )
  end

  defp stamp(state, self, {cx, cy, cz} = cell) do
    since = state.since

    self =
      if since > 0 do
        {vx, _, vz} = self.velocity
        self = %{self | velocity: {vx, 0.3, vz}}
        Enum.reduce(1..3, self, fn _, self -> elem(Self.float(self), 1) end)
      else
        self
      end

    self =
      if rem(since, 2) == 0 do
        {vx, _, vz} = self.velocity
        self = %{self | velocity: {vx, -0.3, vz}}

        if rem(since, 6) == 0 do
          {f, self} = Self.float(self)
          pitch = Float32.round(Float32.round(0.9) + Float32.round(f * Float32.round(0.2)))
          {bx, by, bz} = state.cell

          sound(
            "minecraft:entity.zombie.destroy_egg",
            self,
            {bx + 0.5, by + 0.5, bz + 0.5},
            0.5,
            pitch
          )
        else
          self
        end
      else
        self
      end

    self =
      if since > 60 do
        self = Self.effect(self, {:remove_block, cell})
        self = Enum.reduce(1..60, self, fn _, self -> elem(Self.gaussian(self), 1) end)
        # `playBreakSound`: pitched from the level's random.
        {f, random} = Valimc.AI.Random.float(self.world.random)
        self = %{self | world: %{self.world | random: random}}
        pitch = Float32.round(Float32.round(0.9) + Float32.round(f * Float32.round(0.2)))
        id = Valimc.AI.Facts.sound_id("minecraft:entity.turtle.egg_break")
        at = {cx + 0.5, cy + 0.5, cz + 0.5}
        Self.effect(self, {:sound_at, id, "blocks", at, Float32.round(0.7), pitch})
      else
        self
      end

    {%{state | since: since + 1}, self}
  end

  defp sound(name, self, at, volume, pitch),
    do:
      Self.effect(
        self,
        {:sound_at, Valimc.AI.Facts.sound_id(name), "hostile", at, Float32.round(volume), pitch}
      )
end
