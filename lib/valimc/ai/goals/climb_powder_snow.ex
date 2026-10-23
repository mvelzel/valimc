defmodule Valimc.AI.Goals.ClimbPowderSnow do
  @moduledoc """
  `ClimbOnTopOfPowderSnowGoal`: a mob that walks on powder snow
  (`powder_snow_walkable_mobs`), inside powder snow after its last move,
  jumps while the block above it is powder snow or has no collision.
  """
  use Valimc.AI.Goal
  alias Valimc.Data.{BlockFacts, Blocks, EntityTypes}
  alias Valimc.Protocol.Data

  @walkable MapSet.new(
              Data.tags()["minecraft:entity_type"]["minecraft:powder_snow_walkable_mobs"]
            )
  @powder_snow Blocks.default_state("powder_snow")

  def can_use(state, self) do
    if self.mob.motion.powder_snow and
         MapSet.member?(@walkable, EntityTypes.id(self.type)) do
      {x, y, z} = Self.block(self)
      above = World.block(self.world, {x, y + 1, z})
      climb = above != nil and (above == @powder_snow or empty?(above))
      {climb, state, self}
    else
      {false, state, self}
    end
  end

  # `getCollisionShape(level, pos) == Shapes.empty()` with no entity context.
  defp empty?(state) do
    case BlockFacts.collision(state) do
      {kind, %{boxes: []}} when kind in [:fixed, :offset] -> true
      _ -> false
    end
  end

  def every_tick?(_state), do: true

  def tick(state, self), do: {state, Self.jump(self)}
end
