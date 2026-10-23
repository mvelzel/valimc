defmodule Valimc.AI.Goals.EatBlock do
  @moduledoc """
  `EatBlockGoal` (a sheep grazing): one update in 1,000 (50 for a baby) it
  starts eating when it stands in a block sheep eat or on grass: the eating
  event, its navigation stops, and 20 updates later (two before the end)
  it eats: the grass under it turns to dirt or the plant it stands in is
  destroyed (while mobs may grief, `{:eat_block, cell, how}`), and it
  `ate` (its module's `ate/1`: a sheep's wool grows back).
  """
  use Valimc.AI.Goal
  alias Valimc.Data.Blocks
  alias Valimc.Entity.Animal

  @edible MapSet.new(Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:edible_for_sheep"])
  @grass Blocks.id("grass_block")

  def new, do: %{tick: 0}

  def can_use(state, self) do
    bound = if Animal.animal?(self.type) and Animal.baby?(self.data), do: 50, else: 1000
    {n, self} = Self.int(self, adjusted(state, bound))

    if n != 0 do
      {false, state, self}
    else
      {x, y, z} = Self.block(self)
      {edible?(self, {x, y, z}) or grass?(self, {x, y - 1, z}), state, self}
    end
  end

  def can_continue(state, self), do: {state.tick > 0, state, self}

  def start(state, self) do
    self = self |> Self.effect({:event, 10}) |> Navigation.stop()
    {%{state | tick: adjusted(state, 40)}, self}
  end

  def stop(state, self), do: {%{state | tick: 0}, self}

  def tick(state, self) do
    tick = max(0, state.tick - 1)
    state = %{state | tick: tick}

    if tick == adjusted(state, 4) do
      {x, y, z} = Self.block(self)

      cond do
        edible?(self, {x, y, z}) -> {state, eat(self, {x, y, z}, :destroy)}
        grass?(self, {x, y - 1, z}) -> {state, eat(self, {x, y - 1, z}, :dirt)}
        true -> {state, self}
      end
    else
      {state, self}
    end
  end

  defp eat(self, cell, how) do
    self = if self.world.mob_griefing, do: Self.effect(self, {:eat_block, cell, how}), else: self
    Animal.ate(self)
  end

  defp edible?(self, cell) do
    case World.block(self.world, cell) do
      nil -> false
      state -> MapSet.member?(@edible, Blocks.block_id(state))
    end
  end

  defp grass?(self, cell) do
    case World.block(self.world, cell) do
      nil -> false
      state -> Blocks.block_id(state) == @grass
    end
  end
end
