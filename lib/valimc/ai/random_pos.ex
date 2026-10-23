defmodule Valimc.AI.RandomPos do
  @moduledoc """
  Vanilla's random walk targets (`RandomPos`, `DefaultRandomPos`,
  `LandRandomPos`, `GoalUtils`): ten candidate blocks around the mob, each
  inside the build height, standing on a block that renders solid and with
  no path malus (land targets: moved up out of solid blocks and not in
  water), the best by the mob's walk target value. Draws come from the mob's
  random in vanilla's order. Mobs have no home yet, so nothing restricts
  them.

  `walk_value/2` is `PathfinderMob.getWalkTargetValue`: an animal prefers
  grass (10) and else light, a monster darkness, others nothing.
  """
  alias Valimc.AI.{Facts, Mth, Self, World}
  alias Valimc.Data.Float32

  @sqrt2 Float32.round(:math.sqrt(2.0))
  @half_pi Float32.round(:math.pi() / 2)

  @doc "`DefaultRandomPos.getPos(mob, h, v)`: `{{x, y, z} | nil, self}`."
  def default(%Self{} = self, h, v) do
    best(self, fn self ->
      {direction, self} = direction(self, h, v)
      toward(self, h, direction, false)
    end)
  end

  @doc "`DefaultRandomPos.getPosAway(mob, h, v, from)`."
  def default_away(%Self{} = self, h, v, {ax, _, az}) do
    {dx, dz} = {self.x - ax, self.z - az}

    best(self, fn self ->
      case within(self, 0.0, h * 1.0, v, dx, dz, @half_pi) do
        {nil, self} -> {nil, self}
        {direction, self} -> toward(self, h, direction, false)
      end
    end)
  end

  @doc "`DefaultRandomPos.getPosTowards(mob, h, v, towards, radians)`."
  def default_towards(%Self{} = self, h, v, {tx, _, tz}, radians) do
    {dx, dz} = {tx - self.x, tz - self.z}

    best(self, fn self ->
      case within(self, 0.0, h * 1.0, v, dx, dz, radians) do
        {nil, self} -> {nil, self}
        {direction, self} -> toward(self, h, direction, false)
      end
    end)
  end

  @doc "`LandRandomPos.getPos(mob, h, v)`."
  def land(%Self{} = self, h, v) do
    best(self, fn self ->
      {direction, self} = direction(self, h, v)

      case toward(self, h, direction, true) do
        {nil, self} -> {nil, self}
        {pos, self} -> {out_of_solid(self, pos), self}
      end
    end)
  end

  # `generateRandomPos`: ten draws, the first of the best walk value.
  defp best(self, candidate) do
    {best, _, self} =
      Enum.reduce(1..10, {nil, :neg_infinity, self}, fn _, {best, value, self} ->
        case candidate.(self) do
          {nil, self} ->
            {best, value, self}

          {pos, self} ->
            v = walk_value(self, pos)
            if value == :neg_infinity or v > value, do: {pos, v, self}, else: {best, value, self}
        end
      end)

    case best do
      nil -> {nil, self}
      {x, y, z} -> {{x + 0.5, y * 1.0, z + 0.5}, self}
    end
  end

  # `generateRandomDirection`.
  defp direction(self, h, v) do
    {xt, self} = Self.int(self, 2 * h + 1)
    {yt, self} = Self.int(self, 2 * v + 1)
    {zt, self} = Self.int(self, 2 * h + 1)
    {{xt - h, yt - v, zt - h}, self}
  end

  # `generateRandomDirectionWithinRadians`.
  defp within(self, min, max, v, xd, zd, radians) do
    center = Mth.atan2(zd, xd) - @half_pi
    {f, self} = Self.float(self)
    angle = center + Float32.round(Float32.round(2.0 * f) - 1.0) * radians
    {d, self} = Self.double(self)
    distance = (min + :math.sqrt(d) * (max - min)) * @sqrt2
    {sin, cos} = Valimc.Native.physics_sin_cos(angle)
    xt = -distance * sin
    zt = distance * cos

    if abs(xt) > max or abs(zt) > max do
      {nil, self}
    else
      {yt, self} = Self.int(self, 2 * v + 1)
      {{floor(xt), yt - v, floor(zt)}, self}
    end
  end

  # `generateRandomPosTowardDirection` (no home to lean toward) and the
  # checks of `DefaultRandomPos` (malus) or `LandRandomPos` (none here).
  defp toward(self, _h, {xt, yt, zt}, land) do
    pos = {floor(xt + self.x), floor(yt + self.y), floor(zt + self.z)}
    world = self.world

    ok =
      not World.outside?(world, pos) and stable?(world, pos) and
        (land or not malus?(self, pos))

    {if(ok, do: pos), self}
  end

  # `LandRandomPos.movePosUpOutOfSolid`, then not into water or malus.
  defp out_of_solid(self, {x, y, z} = pos) do
    world = self.world

    pos =
      if World.solid?(world, pos) do
        up = Enum.find((y + 1)..world.max_y//1, &(not World.solid?(world, {x, &1, z})))
        {x, up || world.max_y + 1, z}
      else
        pos
      end

    if World.fluid(world, pos) == :water or malus?(self, pos), do: nil, else: pos
  end

  # `GoalUtils.isNotStable`: `isStableDestination` (a solid-rendering block below).
  defp stable?(world, {x, y, z}), do: World.solid_render?(world, {x, y - 1, z})

  @doc "`GoalUtils.hasMalus`: the mob's malus for the block's path type is not 0."
  def malus?(%Self{} = self, pos), do: malus(self, static(self.world, pos)) != 0.0

  @doc "`Mob.getPathfindingMalus`."
  def malus(%Self{facts: facts}, type), do: Map.fetch!(facts.malus, type)

  @doc """
  `WalkNodeEvaluator.getPathTypeStatic`: an open block over ground is
  walkable, or what borders it (danger, fire, water) taints it.
  """
  def static(world, {x, y, z} = pos) do
    case type(world, pos) do
      :open when y >= world.min_y + 1 ->
        case type(world, {x, y - 1, z}) do
          t when t in [:open, :water, :lava, :walkable] -> :open
          :fire -> :fire
          :damaging -> :damaging
          :sticky_honey -> :sticky_honey
          :powder_snow -> :on_top_of_powder_snow
          :damage_cautious -> :damage_cautious
          :trapdoor -> :on_top_of_trapdoor
          _ -> neighbours(world, pos)
        end

      type ->
        type
    end
  end

  defp neighbours(world, {x, y, z}) do
    Enum.find_value(
      for(dx <- -1..1, dy <- -1..1, dz <- -1..1, dx != 0 or dz != 0, do: {dx, dy, dz}),
      :walkable,
      fn {dx, dy, dz} ->
        case type(world, {x + dx, y + dy, z + dz}) do
          :damaging -> :damaging_in_neighbor
          t when t in [:fire, :lava] -> :fire_in_neighbor
          :water -> :water_border
          :damage_cautious -> :damage_cautious
          _ -> nil
        end
      end
    )
  end

  # An unreadable block blocks.
  defp type(world, pos) do
    case World.block(world, pos) do
      nil -> :blocked
      state -> Facts.path_type(state)
    end
  end

  @grass MapSet.new(Valimc.Data.Blocks.states("grass_block"))

  @doc "`getWalkTargetValue` at a block for the mob's family."
  def walk_value(%Self{type: type, world: world}, {x, y, z} = pos) do
    case family(type) do
      :animal ->
        if MapSet.member?(@grass, World.block(world, {x, y - 1, z})),
          do: 10.0,
          else: Float32.round(World.light(world, pos) - 0.5)

      :monster ->
        -Float32.round(World.light(world, pos) - 0.5)

      _ ->
        0.0
    end
  end

  @monsters ["minecraft:zombie"]
  @animals ["minecraft:pig"]

  defp family(type) when type in @monsters, do: :monster
  defp family(type) when type in @animals, do: :animal
  defp family(_type), do: :other
end
