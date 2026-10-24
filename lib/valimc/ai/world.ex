defmodule Valimc.AI.World do
  @moduledoc """
  What a mob's AI reads beyond itself (VMC-041a): the owner's own state and
  published snapshots, handed in once per section tick. `read` gives the
  state at a block (nil where it cannot be read: an unloaded chunk reads as
  nothing to stand on or see through), `time` the game time, `players` the
  group's playing players, `mobs` the section's mobs and `items` its items
  (`%{kind: :item, uuid, x, y, z, item, count, components, pickup_delay, in_water}`).
  An item's `in_water` is its last physics observation. `random` is the level's
  random (behaviours' run times), `light` the sky and
  block light at a block (`{sky, block}`, nil where unknown) and `darken`
  the sky's darkening (`light/2`: `getLightLevelDependentMagicValue`), `search` how path searches run and
  `paths` the deferred results that arrived (`search/2`), `sea_level` and
  the stationary `border` (`{min_x, min_z, max_x, max_z}`) searches read.
  `dimension` names the world, `day` is the overworld clock's ticks (the
  villager schedule's), `pois` the POI tickets taken (`Valimc.AI.Pois`) and
  `villages` the 16-block sections holding occupied village POIs (nil:
  computed from `pois`) and `stand_up` where a mob of a type stands up from
  a bed (`fn type, head, facing, yaw -> {x, y, z} | nil`, the owner's
  `AbstractBedBlock.findStandUpPosition`; nil: above the bed); `sky`
  whether a block sees the sky.

  Sensing is vanilla's: `TargetingConditions.test` (`test/4`), the nearest
  player or mob a goal asks for (`nearest_player/5`, `nearest_mob/6`),
  `Sensing.hasLineOfSight` through collision shapes, cached per tick in the
  mind (`sees?/2`), and `getVisibilityPercent` of players.

  A sensed player is `%{kind: :player, uuid, id, x, y, z, eye, width,
  height, mode, invulnerable, alive, crouching, swimming, invisible, armor_cover,
  equipment, yaw, pitch, movement}` (`equipment` slot => item id,
  `movement` its known movement, which a lead it holds pulls with); a sensed mob
  `%{kind: :mob, uuid, id, type, x, y, z, eye, width, height, alive, mind}`
  with the parts of its mind others read.
  """
  import Bitwise
  alias Valimc.AI.{Facts, Self}
  alias Valimc.Data.BlockFacts
  alias Valimc.Physics.Clip

  defstruct read: nil,
            # Whether a chunk is loaded (`hasChunk`, `fn {cx, cz} -> bool`), nil:
            # where `read` reads (VMC-043e: a turtle's travel).
            chunks: nil,
            find: nil,
            time: 0,
            players: [],
            mobs: [],
            by_type: %{},
            # The sensed mobs of `mobs` by uuid (nil: `entity/2` scans `mobs`).
            index: nil,
            # Mobs sensed again this tick (moved, or their own state
            # changed), over the snapshot in `mobs` (VMC-043e).
            moved: %{},
            items: [],
            random: 0,
            difficulty: :normal,
            min_y: -64,
            max_y: 319,
            light: nil,
            darken: 0,
            mob_griefing: true,
            mob_drops: true,
            # `entity_drops` (a dropped lead's item) and the fence knots mobs
            # are leashed to, by block: `pos => network id` (VMC-043c3).
            entity_drops: true,
            knots: %{},
            # False: no mob's goals run (tests that move mobs alone).
            goals: true,
            universal_anger: false,
            search: :deferred,
            paths: %{},
            sea_level: 63,
            border: nil,
            # VMC-043b: the overworld clock's ticks (local difficulty, the
            # day's sky), the biome at a block (nil where unknown), whether
            # it is Halloween.
            day: 0,
            biome: nil,
            halloween: false,
            # `isBrightOutside`: the sky darkened by less than 4 where time moves.
            bright: false,
            # Rain at a body's feet and head (`fn position, top -> bool`, nil:
            # none) and whether the day burns monsters now.
            rain: nil,
            monsters_burn: false,
            # A local difficulty that holds everywhere (oracles), else nil.
            local: nil,
            # Seeds for the loot tables mobs roll (a piglin's barter, VMC-043d):
            # nil draws fresh ones, a list (checks) hands them out in order.
            loot_seeds: nil,
            # A melee hit on a mob ticking with the thinking one lands mid-tick
            # (VMC-043e: an axolotl's prey): `fn ref, effects -> killed?`, nil:
            # unknown.
            melee: nil,
            # Read-only collision result for a goal's own move before its controls.
            goal_position: nil,
            # What players did that mobs react to before thinking (VMC-043d):
            # `{:anger, player_ref, seen}` (opening or breaking what piglins guard).
            events: [],
            dimension: :overworld,
            pois: %{},
            villages: nil,
            stand_up: nil,
            sky: nil,
            # The kept starts of structures that override spawns, by chunk
            # (`RegionData` `structures`): a cat's swamp hut (VMC-044a3).
            structures: %{},
            # Authoritative dragon arena/crystal rows and batched block reads.
            dragon: nil

  @doc """
  A path search (VMC-041b): `search` answers it at once (`{path | nil,
  random, chunks}`, oracles and tests) or `:deferred` (an owner runs it as
  a job; the result reaches the mob by `paths`, see `Navigation.receive/1`).
  """
  def search(%__MODULE__{search: :deferred}, _request), do: :deferred
  def search(%__MODULE__{search: search}, request), do: search.(request)

  @doc """
  The seed of a loot table roll a mob makes (vanilla draws the world's
  random sequence for the table): the next of `loot_seeds`, or a fresh one.
  `{seed, world}`.
  """
  def loot_seed(%__MODULE__{loot_seeds: [seed | rest]} = world),
    do: {seed, %{world | loot_seeds: rest}}

  def loot_seed(%__MODULE__{} = world) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    {if(seed == 0, do: 1, else: seed), world}
  end

  @doc """
  `getStructureWithPieceAt(pos, structures).isValid()` over the kept
  starts: a piece of a start of one of `structures` (a set of names) holds
  `position`.
  """
  def in_structure?(%__MODULE__{structures: structures}, {x, _, z} = position, names) do
    inside = fn [x0, y0, z0, x1, y1, z1], {px, py, pz} ->
      px in x0..x1 and py in y0..y1 and pz in z0..z1
    end

    structures
    |> Map.get({x >>> 4, z >>> 4}, [])
    |> Enum.any?(fn {name, _box, pieces} ->
      MapSet.member?(names, name) and Enum.any?(pieces, &inside.(&1, position))
    end)
  end

  @doc "The state at `position` (nil where it cannot be read)."
  def block(%__MODULE__{read: read}, position), do: read.(position)

  @doc "`hasChunk(cx, cz)` (at height `y` where the world reads blocks)."
  def chunk?(%__MODULE__{chunks: nil} = world, {cx, cz}, y),
    do: block(world, {cx * 16, y, cz * 16}) != nil

  def chunk?(%__MODULE__{chunks: chunks}, chunk, _y), do: chunks.(chunk)

  @doc "The blocks of `states` (a set) in an inclusive box: `[{position, state}]`."
  def find(%__MODULE__{find: nil}, _box, _states), do: []
  def find(%__MODULE__{find: find}, box, states), do: find.(box, states)

  @doc "`BlockState.isAir` (an unreadable cell is no air: nothing goes there)."
  def air?(world, position),
    do: (state = block(world, position)) != nil and BlockFacts.air?(state)

  @doc """
  `isInWater` of a sensed entity: water reaching above its feet in a cell
  its box (shrunk by 0.001) touches (VMC-043b2: a drowned's target).
  """
  def in_water?(%__MODULE__{} = world, entity) do
    {x0, y0, z0, x1, y1, z1} = box(entity)

    {x0, y0, z0, x1, y1, z1} =
      {x0 + 0.001, y0 + 0.001, z0 + 0.001, x1 - 0.001, y1 - 0.001, z1 - 0.001}

    Enum.any?(
      for(
        x <- floor(x0)..(ceil(x1) - 1)//1,
        y <- floor(y0)..(ceil(y1) - 1)//1,
        z <- floor(z0)..(ceil(z1) - 1)//1,
        do: {x, y, z}
      ),
      fn {_, y, _} = cell ->
        case block(world, cell) do
          nil ->
            false

          state ->
            fluid = BlockFacts.fluid(state)
            fluid.kind == :water and y + fluid.height >= y0
        end
      end
    )
  end

  @doc """
  `getHeightmapPos(MOTION_BLOCKING)`'s height of column `{x, z}`: above its
  highest block that blocks motion or holds fluid (a phantom's anchor);
  the bottom where none is read.
  """
  def motion_blocking(%__MODULE__{} = world, x, z) do
    top =
      Enum.find(world.max_y..world.min_y//-1, fn y ->
        (state = block(world, {x, y, z})) != nil and
          BlockFacts.heightmap?(state, :motion_blocking)
      end)

    if top, do: top + 1, else: world.min_y
  end

  @doc "`BlockState.isSolid` (legacy solidity)."
  def solid?(world, position),
    do: (state = block(world, position)) != nil and BlockFacts.flag?(state, :solid)

  @doc "Whether the block at `position` has a collision shape (unreadable: yes)."
  def collides?(world, position) do
    case block(world, position) do
      nil ->
        true

      state ->
        {x, y, z} = position
        cell = {x * 1.0, y * 1.0, z * 1.0, x + 1.0, y + 1.0, z + 1.0}
        context = Valimc.Physics.CollisionContext.empty()
        Valimc.Physics.Kernel.obstructs?(state, position, context, [cell])
    end
  end

  @doc """
  `BlockPos.manhattanOrdered` from `origin` within `rx`, `ry`, `rz` up to the
  sum (`withinBoxByManhattanDistance`): nearest first, x then y, z and its
  mirror.
  """
  def manhattan({ox, oy, oz}, rx, ry, rz) do
    for depth <- 0..(rx + ry + rz),
        x <- -min(rx, depth)..min(rx, depth)//1,
        max_y = min(ry, depth - abs(x)),
        y <- -max_y..max_y//1,
        z = depth - abs(x) - abs(y),
        z <= rz,
        p <-
          if(z != 0,
            do: [{ox + x, oy + y, oz + z}, {ox + x, oy + y, oz - z}],
            else: [{ox + x, oy + y, oz}]
          ),
        do: p
  end

  @doc "`BlockState.isRedstoneConductor`."
  def conductor?(world, position),
    do: (state = block(world, position)) != nil and BlockFacts.flag?(state, :redstone_conductor)

  @doc "`BlockState.isSolidRender`."
  def solid_render?(world, position),
    do: (state = block(world, position)) != nil and BlockFacts.flag?(state, :solid_render)

  @doc "The fluid kind at `position` (`:water`, `:lava` or `:empty`)."
  def fluid(world, position) do
    case block(world, position) do
      nil -> :empty
      state -> BlockFacts.fluid(state).kind
    end
  end

  @doc """
  `getLightLevelDependentMagicValue` at a block: its brightness (sky light
  less the sky's darkening, or block light) on vanilla's curve; 0 where the
  light is not known.
  """
  def light(%__MODULE__{light: nil}, _position), do: 0.0

  def light(%__MODULE__{light: light, darken: darken}, position) do
    case light.(position) do
      {sky, block} ->
        v = Valimc.Data.Float32.round(max(sky - darken, block) / 15.0)

        Valimc.Data.Float32.round(
          v / Valimc.Data.Float32.round(4.0 - Valimc.Data.Float32.round(3.0 * v))
        )

      nil ->
        0.0
    end
  end

  @doc "`canSeeSky`: full sky light at the block (never where light is not known)."
  def sees_sky?(%__MODULE__{light: nil}, _position), do: false

  def sees_sky?(%__MODULE__{light: light}, position),
    do: match?({15, _}, light.(position))

  @doc "The biome at `position` (`Level.getBiome`), plains where unknown."
  def biome(%__MODULE__{biome: nil}, _position), do: "minecraft:plains"
  def biome(%__MODULE__{biome: biome}, position), do: biome.(position) || "minecraft:plains"

  @doc """
  `noCollision(box)` over blocks: no collision shape of a cell the box
  reaches (and the cells around it, for tall shapes) meets it; an unreadable
  cell collides.
  """
  def fits?(%__MODULE__{} = world, {x0, y0, z0, x1, y1, z1} = box) do
    context = Valimc.Physics.CollisionContext.empty()

    Enum.all?(
      for(
        x <- (floor(x0 - 1.0e-7) - 1)..(floor(x1 + 1.0e-7) + 1),
        y <- (floor(y0 - 1.0e-7) - 1)..(floor(y1 + 1.0e-7) + 1),
        z <- (floor(z0 - 1.0e-7) - 1)..(floor(z1 + 1.0e-7) + 1),
        do: {x, y, z}
      ),
      fn position ->
        case block(world, position) do
          nil -> false
          state -> not Valimc.Physics.Kernel.obstructs?(state, position, context, [box])
        end
      end
    )
  end

  @doc """
  `canSeeSky` (full sky light) at a block: `sky` reads it (a column's
  lowest sky source); without one, nothing sees the sky.
  """
  def sky?(%__MODULE__{sky: nil} = world, position), do: sees_sky?(world, position)
  def sky?(%__MODULE__{sky: sky}, position), do: sky.(position)

  @doc "`isOutsideBuildHeight`."
  def outside?(%__MODULE__{min_y: min, max_y: max}, {_, y, _}), do: y < min or y > max

  ## Entities

  @doc "The entity a mind's target names, if it is still there."
  def entity(%__MODULE__{players: players}, {:player, uuid}),
    do: Enum.find(players, &(&1.uuid == uuid))

  def entity(%__MODULE__{moved: moved} = world, {:mob, uuid}) do
    case moved do
      %{^uuid => mob} -> mob
      _ -> sensed(world, uuid)
    end
  end

  def entity(%__MODULE__{items: items}, {:item, uuid}), do: Enum.find(items, &(&1.uuid == uuid))
  def entity(_world, nil), do: nil

  defp sensed(%__MODULE__{index: nil, mobs: mobs}, uuid), do: Enum.find(mobs, &(&1.uuid == uuid))
  defp sensed(%__MODULE__{index: index}, uuid), do: Map.get(index, uuid)

  @doc "The reference a mind keeps of a sensed entity."
  def ref(%{kind: kind, uuid: uuid}), do: {kind, uuid}
  def ref(nil), do: nil

  @doc """
  `Mob.getTarget`: the mind's target while valid (`asValidTarget`: not a
  creative or spectator player, one it can attack), else nil.
  """
  def target(%Self{mind: mind, world: world} = self) do
    case entity(world, mind.target) do
      nil -> nil
      %{kind: :player, mode: mode} when mode in [:creative, :spectator] -> nil
      target -> if can_attack?(self, target), do: target
    end
  end

  @doc "`Mob.canAttack` of `target` (players only while not peaceful)."
  def can_attack?(%Self{world: world} = self, target) do
    not (target.kind == :player and world.difficulty == :peaceful) and seen_as_enemy?(target) and
      Map.get(target, :type) != "minecraft:ghast" and
      Valimc.AI.Mobs.hook(self.type, :can_attack?, [self, target], true)
  end

  # `canBeSeenAsEnemy`: not invulnerable (a creative player) and seen at all.
  defp seen_as_enemy?(target), do: not Map.get(target, :invulnerable, false) and seen?(target)

  # `canBeSeenByAnyone`: alive and not a spectator.
  defp seen?(target), do: target.alive and Map.get(target, :mode) != :spectator

  @doc "An entity's eye height in world Y."
  def eye_y(target), do: target.y + target.eye

  @doc "An entity's bounding box (a mob kind's own, if it has one)."
  def box(%{box: {_, _, _, _, _, _} = box}), do: box

  def box(target) do
    half = target.width / 2.0

    {target.x - half, target.y, target.z - half, target.x + half, target.y + target.height,
     target.z + half}
  end

  @doc "`AABB.intersects`."
  def intersects?({ax0, ay0, az0, ax1, ay1, az1}, {bx0, by0, bz0, bx1, by1, bz1}),
    do: ax0 < bx1 and ax1 > bx0 and ay0 < by1 and ay1 > by0 and az0 < bz1 and az1 > bz0

  @doc "`AABB.inflate(x, y, z)`."
  def inflate({x0, y0, z0, x1, y1, z1}, dx, dy, dz),
    do: {x0 - dx, y0 - dy, z0 - dz, x1 + dx, y1 + dy, z1 + dz}

  @doc "`distanceToSqr` between a mob and an entity (feet to feet)."
  def distance_sq(%Self{} = self, target),
    do: Self.distance_sq(self, {target.x, target.y, target.z})

  @doc """
  `TargetingConditions.test(level, self, target)`: `conditions` holds
  `combat` (forCombat), `range` (none below 0), `sight` (line of sight),
  `invisible` (the visibility percent applies) and `select`, a predicate
  of the target (or of the target and the mob).
  `{passes, self}` (a line of sight check is cached in the mind).
  """
  def test(%Self{} = self, target, conditions) do
    cond do
      target.uuid == self.uuid ->
        {false, self}

      not seen?(target) ->
        {false, self}

      conditions[:select] && not select(conditions.select, target, self) ->
        {false, self}

      conditions.combat and not can_attack?(self, target) ->
        {false, self}

      conditions.range > 0.0 and out_of_range?(self, target, conditions) ->
        {false, self}

      conditions.sight ->
        sees?(self, target)

      true ->
        {true, self}
    end
  end

  # A selector reads the target, or the target and the mob (`isAngryAt`).
  defp select(select, target, _self) when is_function(select, 1), do: select.(target)
  defp select(select, target, self), do: select.(target, self)

  defp out_of_range?(self, target, conditions) do
    modifier = if conditions.invisible, do: visibility(target, self.type), else: 1.0
    reach = max(conditions.range * modifier, 2.0)
    distance_sq(self, target) > reach * reach
  end

  @doc "Targeting conditions with vanilla's defaults (`forCombat()` or `forNonCombat()`)."
  def conditions(combat, options \\ []),
    do:
      Map.merge(
        %{combat: combat, range: -1.0, sight: true, invisible: true, select: nil},
        Map.new(options)
      )

  @doc """
  `LivingEntity.getVisibilityPercent` of a player for a mob of `type`:
  crouching, invisibility under its armor cover, and worn items that hide
  their wearer from the type (`mob_visibility`).
  """
  def visibility(%{kind: :player} = target, type) do
    v = 1.0
    v = if target.crouching, do: v * 0.8, else: v

    v =
      if target.invisible,
        do: v * 0.7 * max(target.armor_cover, Valimc.Data.Float32.round(0.1)),
        else: v

    v =
      Enum.reduce(target.equipment, v, fn {slot, item}, v ->
        case hidden(item) do
          %{slot: ^slot, visibility: hidden, types: types} ->
            if type in types, do: v * hidden, else: v

          _ ->
            v
        end
      end)

    min(max(v, 0.0), 10.0)
  end

  def visibility(_target, _type), do: 1.0

  @hidden for name <- [
                "minecraft:creeper_head",
                "minecraft:piglin_head",
                "minecraft:skeleton_skull",
                "minecraft:zombie_head"
              ],
              fact = Facts.visibility(name),
              into: %{},
              do: {Valimc.Protocol.ItemTypes.id(name), fact}

  defp hidden(item), do: @hidden[item]

  @doc """
  `Sensing.hasLineOfSight`: a collision-shape ray from the mob's eye to the
  target's, at most 128 blocks; `{seen, self}`, cached for the tick.
  """
  def sees?(%Self{mind: mind} = self, target) do
    key = {target.kind, target.uuid}

    case mind.sight do
      %{^key => seen} ->
        {seen, self}

      sight ->
        seen = line_of_sight?(self, target)
        {seen, %{self | mind: %{mind | sight: Map.put(sight, key, seen)}}}
    end
  end

  @doc "`LivingEntity.hasLineOfSight` (uncached): eye to eye through collision shapes."
  def line_of_sight?(%Self{} = self, target) do
    from = {self.x, Self.eye_y(self), self.z}
    to = {target.x, eye_y(target), target.z}
    {fx, fy, fz} = from
    {tx, ty, tz} = to

    if :math.sqrt((tx - fx) * (tx - fx) + (ty - fy) * (ty - fy) + (tz - fz) * (tz - fz)) > 128.0 do
      false
    else
      Clip.clip(from, to, :none, &block(self.world, &1), :collider).miss
    end
  end

  @doc """
  `ServerLevel.getNearestPlayer(conditions, self, x, y, z)`: the nearest
  player to the point that passes; `{player | nil, self}`.
  """
  def nearest_player(%Self{} = self, conditions, x, y, z),
    do: nearest(self, self.world.players, conditions, {x, y, z})

  @doc """
  `getNearestEntity` over the section's mobs whose type `select` accepts and
  whose box meets `box`: `{mob | nil, self}`.
  """
  def nearest_mob(%Self{} = self, select, box, conditions, x, y, z) do
    candidates = mobs_in(self, select, box)
    nearest(self, candidates, conditions, {x, y, z})
  end

  @doc """
  `getEntitiesOfClass`: the section's mobs of the types `select` names (a
  list, or a predicate on the type), meeting `box`, in the section's order.
  """
  def mobs_in(%Self{world: world}, types, box) when is_list(types) do
    case for(t <- types, list = Map.get(world.by_type, t), do: list) do
      [] -> []
      [one] -> meeting(world, one, box, nil)
      _ -> meeting(world, world.mobs, box, &(&1 in types))
    end
  end

  def mobs_in(%Self{world: world}, select, box), do: meeting(world, world.mobs, box, select)

  # The mobs of `mobs` whose type `keep` accepts (nil: all), as sensed now,
  # meeting `box`: one pass that reads a moved mob from the overlay.
  defp meeting(%__MODULE__{moved: moved}, mobs, box, keep) do
    mobs
    |> Enum.reduce([], fn m, acc ->
      m = Map.get(moved, m.uuid, m)

      if (keep == nil or keep.(m.type)) and intersects?(box(m), box), do: [m | acc], else: acc
    end)
    |> Enum.reverse()
  end

  @doc "The section's mobs as sensed now, in the section's order."
  def mob_list(%__MODULE__{mobs: mobs} = world), do: now(world, mobs)

  @doc "The section's mobs of type `type` as sensed now."
  def mobs_of(%__MODULE__{by_type: by_type} = world, type),
    do: now(world, Map.get(by_type, type, []))

  defp now(%__MODULE__{moved: moved}, mobs) when map_size(moved) == 0, do: mobs
  defp now(%__MODULE__{moved: moved}, mobs), do: Enum.map(mobs, &Map.get(moved, &1.uuid, &1))

  @doc """
  The world after a melee hit on `ref` (`world.melee`, with the thinker's
  `effects` so far: what its family adds to the hit): a mob it killed is
  sensed dead for the rest of the tick (`isAlive`).
  """
  def melee(%__MODULE__{melee: melee} = world, {:mob, uuid} = ref, effects) when melee != nil do
    if melee.(ref, effects), do: resense(world, uuid, &%{&1 | alive: false}), else: world
  end

  def melee(world, _ref, _effects), do: world

  @doc "The world with mob `uuid` sensed as `fun` changes it."
  def resense(%__MODULE__{} = world, uuid, fun) do
    case entity(world, {:mob, uuid}) do
      nil -> world
      mob -> %{world | moved: Map.put(world.moved, uuid, fun.(mob))}
    end
  end

  @doc "`getNearestEntity` over `candidates`: `{entity | nil, self}`."
  def nearest(%Self{} = self, candidates, conditions, x, y, z),
    do: nearest(self, candidates, conditions, {x, y, z})

  defp nearest(self, candidates, conditions, {x, y, z}) do
    {best, _, self} =
      Enum.reduce(candidates, {nil, -1.0, self}, fn candidate, {best, distance, self} ->
        {passes, self} = test(self, candidate, conditions)

        if passes do
          {dx, dy, dz} = {candidate.x - x, candidate.y - y, candidate.z - z}
          d = dx * dx + dy * dy + dz * dz

          if distance == -1.0 or d < distance,
            do: {candidate, d, self},
            else: {best, distance, self}
        else
          {best, distance, self}
        end
      end)

    {best, self}
  end
end
