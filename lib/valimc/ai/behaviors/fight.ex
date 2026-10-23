defmodule Valimc.AI.Behaviors.Fight do
  @moduledoc """
  Brain behaviours of fighting and of the memories around it (VMC-043d), as
  vanilla's `ai.behavior` classes build them, shared by every brain mob
  (piglins, hoglins, later wardens and villagers' golems):

  - `start_attacking/2` (`StartAttacking`), `stop_if_invalid/2`
    (`StopAttackingIfTargetInvalid`), `walk_to_target/1`
    (`SetWalkTargetFromAttackTargetIfTargetOutOfReach`), `melee/2`
    (`MeleeAttack`): a hit through `Mob.doHurtTarget` (an `{:attack,
    target}` effect, VMC-037n) with a main-hand swing;
  - `copy_with_expiry/4` (`CopyMemoryWithExpiry`), `erase_if/2`
    (`EraseMemoryIf`), `walk_away/5` (`SetWalkTargetAwayFrom`),
    `go_to_location/3` (`GoToTargetLocation`),
    `celebrate_if_target_dead/2` (`StartCelebratingIfTargetDead`) and
    `stop_angry_if_target_dead/0` (`StopBeingAngryIfTargetDead`).

  The attack target is kept by reference (`World.ref/1`), as the look and
  walk targets are trackers (`Valimc.AI.Behaviors`).
  """
  alias Valimc.AI.{Behavior, Behaviors, Brain, RandomPos, Self, Sensors, World}
  alias Valimc.Data.Float32

  @doc """
  `StartAttacking.create(condition, finder)`: with no attack target, a
  target the finder gives (`{entity | nil, self}`) that the mob can attack.
  """
  def start_attacking(condition, finder) do
    Behavior.one_shot(
      [attack_target: :absent, cant_reach_walk_target_since: :registered],
      fn self ->
        if condition.(self) do
          case finder.(self) do
            {nil, self} ->
              {false, self}

            {target, self} ->
              if World.can_attack?(self, target) do
                self =
                  self
                  |> Brain.set(:attack_target, World.ref(target))
                  |> Brain.erase(:cant_reach_walk_target_since)

                {true, self}
              else
                {false, self}
              end
          end
        else
          {false, self}
        end
      end
    )
  end

  @doc """
  `StopAttackingIfTargetInvalid.create(stopWhen)`: the target is dropped
  when it cannot be attacked, has not been reached for 200 ticks, is dead or
  gone, or `stop_when.(self, target)` (`{stop, self}`).
  """
  def stop_if_invalid(stop_when \\ fn self, _ -> {false, self} end, tired \\ true) do
    Behavior.one_shot(
      [attack_target: :present, cant_reach_walk_target_since: :registered],
      fn self ->
        target = World.entity(self.world, Brain.get(self, :attack_target))

        {keep, self} =
          cond do
            target == nil ->
              {false, self}

            not World.can_attack?(self, target) ->
              {false, self}

            tired and tired?(self) ->
              {false, self}

            not target.alive ->
              {false, self}

            true ->
              {stop, self} = stop_when.(self, target)
              {not stop, self}
          end

        {true, if(keep, do: self, else: Brain.erase(self, :attack_target))}
      end
    )
  end

  defp tired?(self) do
    case Brain.get(self, :cant_reach_walk_target_since) do
      nil -> false
      since -> self.world.time - since > 200
    end
  end

  @doc """
  `SetWalkTargetFromAttackTargetIfTargetOutOfReach.create(speed)`: a target
  in sight within reach needs no walk; else look at it and walk to it.
  """
  def walk_to_target(speed) do
    speed = Float32.round(speed)

    Behavior.one_shot(
      [
        walk_target: :registered,
        look_target: :registered,
        attack_target: :present,
        nearest_visible_living_entities: :registered
      ],
      fn self ->
        target = World.entity(self.world, Brain.get(self, :attack_target))

        if target == nil do
          {true, self}
        else
          {visible, self} =
            if Brain.has?(self, :nearest_visible_living_entities),
              do: Sensors.visible_contains?(self, target),
              else: {false, self}

          if visible and within_attack_range?(self, target, 1) do
            {true, Brain.erase(self, :walk_target)}
          else
            ref = World.ref(target)

            self =
              self
              |> Brain.set(:look_target, {:entity, ref, true})
              |> Brain.set(:walk_target, %{target: {:entity, ref, false}, speed: speed, close: 0})

            {true, self}
          end
        end
      end
    )
  end

  @doc """
  `BehaviorUtils.isWithinAttackRange(body, target, buffer)`: a mob holding
  a projectile weapon within its range less `buffer`, else within melee
  reach.
  """
  def within_attack_range?(self, target, buffer) do
    case projectile_range(self) do
      nil ->
        within_melee?(self, target)

      range ->
        r = range - buffer
        World.distance_sq(self, target) <= r * r
    end
  end

  @crossbow Valimc.Protocol.ItemTypes.id("minecraft:crossbow")
  @bow Valimc.Protocol.ItemTypes.id("minecraft:bow")

  # `ProjectileWeaponItem.getDefaultProjectileRange`: a crossbow's 8, a bow's 15.
  defp projectile_range(%Self{mob: mob}) do
    hands = [mob.equipment[:mainhand], mob.equipment[:offhand]]

    cond do
      Enum.any?(hands, &match?(%{item_id: @crossbow}, &1)) -> 8
      Enum.any?(hands, &match?(%{item_id: @bow}, &1)) -> 15
      true -> nil
    end
  end

  @reach :math.sqrt(Float32.round(2.04)) - Float32.round(0.6)

  @doc "`Mob.isWithinMeleeAttackRange` (default reach): its box widened meets the target's."
  def within_melee?(self, target),
    do: World.intersects?(World.inflate(Self.box(self), @reach, 0.0, @reach), World.box(target))

  @doc """
  `MeleeAttack.create(predicate, cooldown)`: a target in sight within reach,
  while not holding a weapon it shoots or thrusts with: a main-hand swing,
  the hit, and `cooldown` ticks before the next.
  """
  def melee(predicate \\ fn _ -> true end, cooldown) do
    Behavior.one_shot(
      [
        look_target: :registered,
        attack_target: :present,
        attack_cooling_down: :absent,
        nearest_visible_living_entities: :present
      ],
      fn self ->
        target = World.entity(self.world, Brain.get(self, :attack_target))

        if target != nil and predicate.(self) and not non_melee?(self) and
             within_melee?(self, target) do
          case Sensors.visible_contains?(self, target) do
            {true, self} ->
              ref = World.ref(target)

              self =
                self
                |> Brain.set(:look_target, {:entity, ref, true})
                |> Self.effect(:swing)
                |> Self.effect({:attack, ref})
                |> Brain.set(:attack_cooling_down, true, cooldown)

              {true, self}

            {false, self} ->
              {false, self}
          end
        else
          {false, self}
        end
      end
    )
  end

  # `isHoldingUsableNonMeleeWeapon`: a crossbow (`canUseNonMeleeWeapon`) or
  # a kinetic weapon (spears).
  defp non_melee?(%Self{mob: mob}) do
    Enum.any?([mob.equipment[:mainhand], mob.equipment[:offhand]], fn
      nil ->
        false

      %{item_id: @crossbow} ->
        true

      stack ->
        Map.has_key?(
          Valimc.Protocol.ItemTypes.defaults(stack.item_id),
          "minecraft:kinetic_weapon"
        )
    end)
  end

  @doc """
  `CopyMemoryWithExpiry.create(predicate, source, target, {min, max})`: a
  copy of `source` into an empty `target` for a duration drawn from the
  level's random.
  """
  def copy_with_expiry(predicate, source, target, {min, max}) do
    Behavior.one_shot([{source, :present}, {target, :absent}], fn self ->
      if predicate.(self) do
        {n, self} = Behavior.level_int(self, max - min + 1)
        {true, Brain.set(self, target, Brain.get(self, source), min + n)}
      else
        {false, self}
      end
    end)
  end

  @doc "`EraseMemoryIf.create(predicate, memory)`."
  def erase_if(predicate, memory) do
    Behavior.one_shot([{memory, :present}], fn self ->
      if predicate.(self), do: {true, Brain.erase(self, memory)}, else: {false, self}
    end)
  end

  @doc """
  `SetWalkTargetAwayFrom.pos` (`kind: :pos`, a block's bottom center) or
  `.entity` (`kind: :entity`): within `distance` of what `memory` holds, a
  land target 16 blocks away from it (ten tries), unless walking already
  (`interrupt` false) or walking away at the same speed.
  """
  def walk_away(memory, kind, speed, distance, interrupt) do
    speed = Float32.round(speed)

    Behavior.one_shot([{:walk_target, :registered}, {memory, :present}], fn self ->
      walk = Brain.get(self, :walk_target)

      avoid =
        case kind do
          :pos ->
            {x, y, z} = Brain.get(self, memory)
            {x + 0.5, y * 1.0, z + 0.5}

          :entity ->
            case World.entity(self.world, Brain.get(self, memory)) do
              nil -> nil
              e -> {e.x, e.y, e.z}
            end
        end

      cond do
        avoid == nil ->
          {false, self}

        walk != nil and not interrupt ->
          {false, self}

        Self.distance_sq(self, avoid) >= distance * distance ->
          {false, self}

        walk != nil and walk.speed == speed and away?(self, walk, avoid) ->
          {false, self}

        true ->
          {true, flee(self, avoid, speed, 10)}
      end
    end)
  end

  # Already walking away: the walk's direction against the threat's.
  defp away?(self, walk, {ax, ay, az}) do
    case Behaviors.position(self, walk.target) do
      nil ->
        false

      {wx, wy, wz} ->
        (wx - self.x) * (ax - self.x) + (wy - self.y) * (ay - self.y) +
          (wz - self.z) * (az - self.z) < 0.0
    end
  end

  defp flee(self, _avoid, _speed, 0), do: self

  defp flee(self, avoid, speed, tries) do
    case RandomPos.land_away(self, 16, 7, avoid) do
      {nil, self} ->
        flee(self, avoid, speed, tries - 1)

      {pos, self} ->
        Brain.set(self, :walk_target, %{target: Behaviors.point(pos), speed: speed, close: 0})
    end
  end

  @doc """
  `GoToTargetLocation.create(memory, close, speed)`: unless close enough to
  the location, walk and look at a block next to it (offsets from the
  level's random).
  """
  def go_to_location(memory, close, speed) do
    speed = Float32.round(speed)

    Behavior.one_shot(
      [
        {memory, :present},
        attack_target: :absent,
        walk_target: :absent,
        look_target: :registered
      ],
      fn self ->
        {x, y, z} = location = Brain.get(self, memory)
        {bx, by, bz} = Self.block(self)
        d = (x - bx) * (x - bx) + (y - by) * (y - by) + (z - bz) * (z - bz)

        if d < close * close do
          {true, self}
        else
          {dx, self} = Behavior.level_int(self, 3)
          {dz, self} = Behavior.level_int(self, 3)
          _ = location
          target = {x + dx - 1, y, z + dz - 1}
          tracker = {:block, target, block_center(target)}

          self =
            self
            |> Brain.set(:walk_target, %{target: tracker, speed: speed, close: close})
            |> Brain.set(:look_target, tracker)

          {true, self}
        end
      end
    )
  end

  defp block_center({x, y, z}), do: {x + 0.5, y + 0.5, z + 0.5}

  @doc """
  `StartCelebratingIfTargetDead.create(duration, dance)`: a dead attack
  target is celebrated where it fell for `duration` ticks (dancing too, if
  `dance.(self, target)`), and forgotten unless it was a player (vanilla's
  `forgiveDeadPlayers` is on by default: forgotten too).
  """
  def celebrate_if_target_dead(duration, dance) do
    Behavior.one_shot(
      [
        attack_target: :present,
        angry_at: :registered,
        celebrate_location: :absent,
        dancing: :registered
      ],
      fn self ->
        case World.entity(self.world, Brain.get(self, :attack_target)) do
          %{alive: false} = target ->
            {dances, self} = dance.(self, target)
            self = if dances, do: Brain.set(self, :dancing, true, duration), else: self
            at = {floor(target.x), floor(target.y), floor(target.z)}

            self =
              self
              |> Brain.set(:celebrate_location, at, duration)
              |> Brain.erase(:attack_target)
              |> Brain.erase(:angry_at)

            {true, self}

          _ ->
            {false, self}
        end
      end
    )
  end

  @doc "`StopBeingAngryIfTargetDead.create()`: anger at a dead entity ends."
  def stop_angry_if_target_dead do
    Behavior.one_shot([angry_at: :present], fn self ->
      case World.entity(self.world, Brain.get(self, :angry_at)) do
        %{alive: false} -> {true, Brain.erase(self, :angry_at)}
        _ -> {true, self}
      end
    end)
  end
end
