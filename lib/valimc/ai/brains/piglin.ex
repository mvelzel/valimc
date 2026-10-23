defmodule Valimc.AI.Brains.Piglin do
  @moduledoc """
  A piglin's brain (`PiglinAi`, VMC-041a2): its sensors, and the core,
  idle and admire activities with vanilla's behaviours in vanilla's order.

  - **Core:** the look and walk sinks; stop holding an admired item when
    admiring ends; start admiring a wanted gold item it sees. (Opening
    doors, fleeing nemeses and zombified piglins, celebrating and anger are
    VMC-043d's: they need mobs or memories nothing sets yet.)
  - **Idle:** look at a player holding what it loves; looks at players,
    piglins or anything near, or nothing (one at random); a random stroll,
    walking to a piglin or to what it looks at, or nothing; look at a
    player close by. (Attacking players without gold armor, hunting
    hoglins, avoiding soul fire and riding are VMC-043d's.)
  - **Admire item:** while admiring, walk to the item; stop if it is too
    far or out of reach too long.

  It picks up a gold item it wants into its off hand and admires it for
  119 ticks (`PiglinAi.pickUpItem`). When admiring ends it lets the item
  go: a gold ingot is its barter (VMC-043d), the bartering table's items
  thrown toward the player it sees or a spot near it; another loved item it
  drops.
  """
  alias Valimc.AI.{Behavior, Behaviors, Brain, Navigation, Random, Self, Sensors, World}
  alias Valimc.AI.Behaviors.Fight
  alias Valimc.Protocol.{Data, ItemTypes}

  @tags Data.tags()["minecraft:item"]
  @loved MapSet.new(@tags["minecraft:piglin_loved"])
  @safe_armor MapSet.new(@tags["minecraft:piglin_safe_armor"])
  @repellents MapSet.new(@tags["minecraft:piglin_repellents"])
  @food MapSet.new(@tags["minecraft:piglin_food"])
  @gold_ingot ItemTypes.id("minecraft:gold_ingot")
  @admire 119

  @doc "Whether `item` (an item id) is loved by piglins."
  def loved?(item), do: MapSet.member?(@loved, item)

  @doc "`PiglinAi.isWearingSafeArmor` of a sensed player."
  def safe_armor?(%{equipment: equipment}),
    do: Enum.any?([:head, :chest, :legs, :feet], &MapSet.member?(@safe_armor, equipment[&1]))

  @doc "`PiglinAi.isPlayerHoldingLovedItem` of a sensed player."
  def holding_loved?(%{kind: :player, equipment: equipment}),
    do: loved?(equipment[:mainhand]) or loved?(equipment[:offhand])

  def holding_loved?(_), do: false

  @sensors [
    {Sensors.NearestLiving, 20},
    {Sensors.Players, 20},
    {Sensors.Items, 20},
    {Sensors.HurtBy, 20},
    {__MODULE__.Sensor, 20}
  ]

  @zombified ["minecraft:zombified_piglin", "minecraft:zoglin"]
  @piglins ["minecraft:piglin", "minecraft:piglin_brute"]

  @doc """
  A piglin's brain, its sensors' countdowns drawn from the mob's `random`
  (as its constructor draws them) and its `RunOne`s shuffled by `gates`
  (five randoms: the idle look and walk, the celebration's, and the
  retreat's look and walk): `{brain, random}`.
  """
  def brain(random, [look_gate, move_gate, celebrate_gate, avoid_look_gate, avoid_move_gate]) do
    core = [
      Behaviors.look_sink(45, 90),
      Behaviors.move_sink(),
      Behavior.inert("InteractWithDoor"),
      Fight.copy_with_expiry(
        &baby?/1,
        :nearest_visible_nemesis,
        :avoid_target,
        {100, 140}
      ),
      Fight.copy_with_expiry(
        &near_zombified?/1,
        :nearest_visible_zombified,
        :avoid_target,
        {100, 140}
      ),
      stop_holding(),
      start_admiring(@admire),
      Fight.celebrate_if_target_dead(300, &wants_to_dance/2),
      Fight.stop_angry_if_target_dead()
    ]

    idle = [
      Behaviors.look_target(&holding_loved?/1, 14.0),
      Fight.start_attacking(&(not baby?(&1)), &find_target/1),
      Behavior.inert("StartHuntingHoglin"),
      Fight.walk_away(:nearest_repellent, :pos, 1.0, 8, false),
      Behavior.inert("babySometimesRideBabyHoglin"),
      Behavior.run_one(look_behaviors(), look_gate),
      Behavior.run_one(move_behaviors(), move_gate),
      Behaviors.look_and_interact(:player, 4)
    ]

    admire = [
      Behaviors.go_to_wanted_item(&not_holding_loved?/1, 1.0, true, 9),
      stop_if_too_far(9),
      stop_if_tired(200, 200)
    ]

    fight = [
      Fight.stop_if_invalid(fn self, target ->
        {nearest, self} = nearest_target?(self, target)
        {not nearest, self}
      end),
      Behavior.inert("BackUpIfTooClose"),
      Fight.walk_to_target(1.0),
      Behavior.inert("SpearApproach"),
      Behavior.inert("SpearAttack"),
      Behavior.inert("SpearRetreat"),
      Fight.melee(20),
      Behavior.inert("CrossbowAttack"),
      remember_hoglin_killed(),
      Fight.erase_if(&near_zombified?/1, :attack_target)
    ]

    celebrate = [
      Fight.walk_away(:nearest_repellent, :pos, 1.0, 8, false),
      Behaviors.look_target(&holding_loved?/1, 14.0),
      Fight.start_attacking(&(not baby?(&1)), &find_target/1),
      Behaviors.trigger_if(
        &(not dancing?(&1)),
        Fight.go_to_location(:celebrate_location, 2, 1.0)
      ),
      Behaviors.trigger_if(&dancing?/1, Fight.go_to_location(:celebrate_location, 4, 0.6)),
      Behavior.run_one(
        [
          {Behaviors.look_target(&Behaviors.is?(&1, "minecraft:piglin"), 8.0), 1},
          {Behaviors.stroll(0.6, 2, 1), 1},
          {Behavior.do_nothing(10, 20), 1}
        ],
        celebrate_gate
      )
    ]

    avoid = [
      Fight.walk_away(:avoid_target, :entity, 1.0, 12, true),
      Behavior.run_one(look_behaviors(), avoid_look_gate),
      Behavior.run_one(move_behaviors(), avoid_move_gate),
      Fight.erase_if(&wants_to_stop_fleeing?/1, :avoid_target)
    ]

    # Riding (VMC-046) waits for vehicles: nothing sets a ride target yet.
    ride = [
      Behavior.inert("Mount"),
      Behavior.inert("SetEntityLookTarget"),
      Behavior.inert("RideSequence"),
      Behavior.inert("DismountOrSkipMounting")
    ]

    Brain.new(
      __MODULE__,
      @sensors,
      [
        {:core, 0, core, [], []},
        {:idle, 10, idle, [], []},
        {:admire_item, 10, admire, [admiring_item: :present], [:admiring_item]},
        {:fight, 10, fight, [attack_target: :present], [:attack_target]},
        {:celebrate, 10, celebrate, [celebrate_location: :present], [:celebrate_location]},
        {:avoid, 10, avoid, [avoid_target: :present], [:avoid_target]},
        {:ride, 10, ride, [ride_target: :present], [:ride_target]}
      ],
      random
    )
  end

  defp look_behaviors,
    do: [
      {Behaviors.look_target(&Behaviors.is?(&1, :player), 8.0), 1},
      {Behaviors.look_target(&Behaviors.is?(&1, "minecraft:piglin"), 8.0), 1},
      {Behaviors.look_target(fn _ -> true end, 8.0), 1},
      {Behavior.do_nothing(30, 60), 1}
    ]

  defp move_behaviors,
    do: [
      {Behaviors.stroll(0.6), 2},
      {Behaviors.interact_with("minecraft:piglin", 8, 0.6, 2), 2},
      {Behaviors.walk_to_look_target(
         &(not Brain.has?(&1, :nearest_player_holding_wanted_item)),
         0.6,
         3
       ), 2},
      {Behavior.do_nothing(30, 60), 1}
    ]

  @doc "The seeds of a fresh piglin's five `RunOne` randoms, from its uuid."
  def gates(<<a::64, b::64>>),
    do:
      for(
        salt <- [0x5A17, 0x9E37, 0x3C6E, 0x7F4A, 0x1B5D],
        do: Random.new(Bitwise.bxor(Bitwise.bxor(a, b * salt), salt))
      )

  @doc "Whether the piglin is a baby."
  def baby?(%Self{data: data}), do: Map.get(data, :baby, false)

  defp dancing?(%Self{data: data}), do: Map.get(data, :dancing, false)

  # `PiglinAi.isNearZombified`: the zombified one it sees within six blocks.
  defp near_zombified?(self) do
    case World.entity(self.world, Brain.get(self, :nearest_visible_zombified)) do
      nil -> false
      z -> World.distance_sq(self, z) < 36.0
    end
  end

  # `wantsToDance`: one time in ten after killing a hoglin, from a random
  # seeded with the game time.
  defp wants_to_dance(self, %{type: "minecraft:hoglin"}) do
    {f, _} = Random.float(Random.new(self.world.time))
    {f < Valimc.Data.Float32.round(0.1), self}
  end

  defp wants_to_dance(self, _target), do: {false, self}

  # `RememberIfHoglinWasKilled`: a dead hoglin target means no hunt for a while.
  defp remember_hoglin_killed do
    Behavior.one_shot([attack_target: :present, hunted_recently: :registered], fn self ->
      case World.entity(self.world, Brain.get(self, :attack_target)) do
        %{type: "minecraft:hoglin", alive: false} -> {true, dont_hunt(self)}
        _ -> {false, self}
      end
    end)
  end

  # `dontKillAnyMoreHoglinsForAWhile`: 30 to 120 seconds (the level's random).
  defp dont_hunt(self) do
    {n, self} = Behavior.level_int(self, 1801)
    Brain.set(self, :hunted_recently, true, 600 + n)
  end

  # `wantsToStopFleeing`: from zombified ones it no longer sees nearest;
  # from hoglins once piglins match their number.
  defp wants_to_stop_fleeing?(self) do
    case World.entity(self.world, Brain.get(self, :avoid_target)) do
      nil ->
        true

      %{type: "minecraft:hoglin"} ->
        not hoglins_outnumber?(self)

      %{type: type} = avoided when type in @zombified ->
        Brain.get(self, :nearest_visible_zombified) != World.ref(avoided)

      _ ->
        false
    end
  end

  defp hoglins_outnumber?(self),
    do:
      (Brain.get(self, :visible_adult_hoglin_count) || 0) >
        (Brain.get(self, :visible_adult_piglin_count) || 0) + 1

  ## Targets and anger

  @doc """
  `PiglinAi.findNearestValidAttackTarget`: none beside a zombified one;
  else whom it is angry at (if it can attack it, sight aside), any player
  under universal anger, a nemesis (a wither skeleton) or the nearest
  player wearing no gold. `{target | nil, self}`.
  """
  def find_target(self) do
    angry = World.entity(self.world, Brain.get(self, :angry_at))

    cond do
      near_zombified?(self) ->
        {nil, self}

      angry != nil and attackable_ignoring_sight?(self, angry) ->
        {angry, self}

      Brain.has?(self, :universal_anger) and
          Brain.has?(self, :nearest_visible_attackable_player) ->
        {World.entity(self.world, Brain.get(self, :nearest_visible_attackable_player)), self}

      (nemesis = World.entity(self.world, Brain.get(self, :nearest_visible_nemesis))) != nil ->
        {nemesis, self}

      (player =
         World.entity(self.world, Brain.get(self, :nearest_targetable_player_not_wearing_gold))) !=
          nil ->
        case Sensors.attackable?(self, player) do
          {true, self} -> {player, self}
          {false, self} -> {nil, self}
        end

      true ->
        {nil, self}
    end
  end

  # `isNearestValidAttackTarget`.
  defp nearest_target?(self, target) do
    {found, self} = find_target(self)
    {found != nil and World.ref(found) == World.ref(target), self}
  end

  # `Sensor.isEntityAttackableIgnoringLineOfSight`.
  defp attackable_ignoring_sight?(self, target) do
    follow = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:follow_range")
    conditions = World.conditions(true, range: follow, sight: false, invisible: false)
    elem(World.test(self, target, conditions), 0)
  end

  @doc """
  What a piglin reacts to before its section thinks (`Valimc.AI`): a hurt
  by `ref` (`wasHurtBy`) or a player stirring the piglins around it
  (`angerNearbyPiglins`).
  """
  def react(self, {:hurt_by, ref}), do: hurt_by(self, ref)

  def react(self, {:anger, player, seen}) do
    case World.entity(self.world, player) do
      nil -> self
      p -> anger_from(self, p, seen)
    end
  end

  def react(self, _event), do: self

  @doc """
  `PiglinAi.wasHurtBy` (VMC-043d), run before the piglins of its section
  think: hurt by anything but a piglin, it lets go of what it holds (no
  barter), stops celebrating, dancing and admiring (a player stops its
  admiring for 20 seconds) and fleeing from another kind; a baby flees
  the attacker and has the adults angry at it; an adult outnumbered by
  hoglins flees one; else it retaliates.
  """
  def hurt_by(%Self{} = self, ref) do
    case World.entity(self.world, ref) do
      nil -> self
      %{type: type} when type in @piglins -> self
      attacker -> hurt_by_entity(self, attacker)
    end
  end

  defp hurt_by_entity(self, attacker) do
    self =
      case offhand(self) do
        nil -> self
        _ -> let_go(self)
      end

    self =
      self
      |> Brain.erase(:celebrate_location)
      |> Brain.erase(:dancing)
      |> Brain.erase(:admiring_item)

    self =
      if attacker.kind == :player,
        do: Brain.set(self, :admiring_disabled, true, 400),
        else: self

    self =
      case World.entity(self.world, Brain.get(self, :avoid_target)) do
        nil ->
          self

        avoided ->
          if type_of(avoided) != type_of(attacker),
            do: Brain.erase(self, :avoid_target),
            else: self
      end

    cond do
      baby?(self) ->
        self = Brain.set(self, :avoid_target, World.ref(attacker), 100)

        if attackable_ignoring_sight?(self, attacker),
          do: broadcast_anger(self, attacker),
          else: self

      attacker[:type] == "minecraft:hoglin" and hoglins_outnumber?(self) ->
        self |> avoid_and_rest(attacker) |> broadcast_retreat(attacker)

      true ->
        retaliate(self, attacker)
    end
  end

  defp type_of(%{kind: :player}), do: "minecraft:player"
  defp type_of(%{type: type}), do: type

  # `stopHoldingOffHandItem(level, body, false)`: an adult's gold ingot is
  # gone with no barter; another item it keeps (dropped until it has an
  # inventory).
  defp let_go(self) do
    stack = offhand(self)
    self = %{self | mob: %{self.mob | equipment: Map.delete(self.mob.equipment, :offhand)}}

    if stack.item_id == @gold_ingot and not baby?(self),
      do: self,
      else: Self.effect(self, {:drop, stack})
  end

  # `maybeRetaliate`: not while fleeing, at an attacker it can attack (sight
  # aside) not much farther than its current target.
  defp retaliate(self, attacker) do
    cond do
      Brain.active?(self, :avoid) ->
        self

      not attackable_ignoring_sight?(self, attacker) ->
        self

      Fight.much_farther?(self, attacker, 4.0) ->
        self

      true ->
        self |> set_anger(attacker) |> broadcast_anger(attacker)
    end
  end

  @doc "`PiglinAi.setAngerTarget`: angry for 30 seconds at a target it can attack."
  def set_anger(self, target) do
    if attackable_ignoring_sight?(self, target) do
      self =
        self
        |> Brain.erase(:cant_reach_walk_target_since)
        |> Brain.set(:angry_at, World.ref(target), 600)

      self =
        if target[:type] == "minecraft:hoglin" and can_hunt?(self),
          do: dont_hunt(self),
          else: self

      if target.kind == :player and self.world.universal_anger,
        do: Brain.set(self, :universal_anger, true, 600),
        else: self
    else
      self
    end
  end

  defp can_hunt?(self), do: not Map.get(self.data, :cannot_hunt, false)

  # `broadcastAngerTarget`: the adults around it, each angry at the nearer
  # of what it was and this.
  defp broadcast_anger(self, target) do
    ref = World.ref(target)

    for(other <- Brain.get(self, :nearby_adult_piglins) || [], do: other)
    |> Enum.reduce(self, fn {:mob, uuid}, self ->
      Self.effect(self, {:brain, uuid, &anger_if_closer(&1, ref)})
    end)
  end

  # `setAngerTargetIfCloserThanCurrent`.
  defp anger_if_closer(self, ref) do
    case World.entity(self.world, ref) do
      nil ->
        self

      new ->
        current = World.entity(self.world, Brain.get(self, :angry_at))

        nearest =
          if current != nil and World.distance_sq(self, current) < World.distance_sq(self, new),
            do: current,
            else: new

        if current == nil or World.ref(current) != World.ref(nearest),
          do: set_anger(self, nearest),
          else: self
    end
  end

  # `setAvoidTargetAndDontHuntForAWhile`.
  defp avoid_and_rest(self, target) do
    {n, self} = Behavior.level_int(self, 301)

    self
    |> Brain.erase(:angry_at)
    |> Brain.erase(:attack_target)
    |> Brain.erase(:walk_target)
    |> Brain.set(:avoid_target, World.ref(target), 100 + n)
    |> dont_hunt()
  end

  # `broadcastRetreat`: the adults it sees flee the nearest of their threats.
  defp broadcast_retreat(self, target) do
    ref = World.ref(target)

    (Brain.get(self, :nearest_visible_adult_piglins) || [])
    |> Enum.reduce(self, fn {:mob, uuid}, self ->
      Self.effect(self, {:brain, uuid, &retreat_from_nearest(&1, ref)})
    end)
  end

  defp retreat_from_nearest(self, ref) do
    case World.entity(self.world, ref) do
      nil ->
        self

      target ->
        nearest =
          [Brain.get(self, :avoid_target), Brain.get(self, :attack_target)]
          |> Enum.reduce(target, fn ref, nearest ->
            case World.entity(self.world, ref) do
              nil ->
                nearest

              other ->
                if World.distance_sq(self, other) < World.distance_sq(self, nearest),
                  do: other,
                  else: nearest
            end
          end)

        avoid_and_rest(self, nearest)
    end
  end

  @doc """
  `PiglinAi.angerNearbyPiglins` (a player opening or breaking what piglins
  guard): an idle piglin within 16 blocks of the player, seeing it if
  `seen`, is angry at it.
  """
  def anger_from(%Self{} = self, player, seen) do
    box = World.inflate(World.box(player), 16.0, 16.0, 16.0)

    cond do
      not Brain.active?(self, :idle) ->
        self

      not World.intersects?(Self.box(self), box) ->
        self

      seen and not elem(Sensors.visible_contains?(self, player), 0) ->
        self

      true ->
        set_anger(self, player)
    end
  end

  ## Core and admire behaviours

  defp offhand(self), do: self.mob.equipment[:offhand]

  defp not_holding_loved?(self) do
    case offhand(self) do
      nil -> true
      stack -> not loved?(stack.item_id)
    end
  end

  # `StopHoldingItemIfNoLongerAdmiring`.
  defp stop_holding do
    Behavior.one_shot([admiring_item: :absent], fn self ->
      case offhand(self) do
        nil -> {false, self}
        _stack -> {true, stop_holding_offhand(self)}
      end
    end)
  end

  # `StartAdmiringItemIfSeen`.
  defp start_admiring(duration) do
    Behavior.one_shot(
      [
        nearest_visible_wanted_item: :present,
        admiring_item: :absent,
        admiring_disabled: :absent,
        disable_walk_to_admire_item: :absent
      ],
      fn self ->
        case World.entity(self.world, Brain.get(self, :nearest_visible_wanted_item)) do
          %{item: item} ->
            if loved?(item),
              do: {true, Brain.set(self, :admiring_item, true, duration)},
              else: {false, self}

          _ ->
            {false, self}
        end
      end
    )
  end

  # `StopAdmiringIfItemTooFarAway`.
  defp stop_if_too_far(distance) do
    Behavior.one_shot(
      [admiring_item: :present, nearest_visible_wanted_item: :registered],
      fn self ->
        item = World.entity(self.world, Brain.get(self, :nearest_visible_wanted_item))

        cond do
          offhand(self) != nil -> {false, self}
          item != nil and World.distance_sq(self, item) < distance * distance -> {false, self}
          true -> {true, Brain.erase(self, :admiring_item)}
        end
      end
    )
  end

  # `StopAdmiringIfTiredOfTryingToReachItem`.
  defp stop_if_tired(most, disable) do
    Behavior.one_shot(
      [
        admiring_item: :present,
        nearest_visible_wanted_item: :present,
        time_trying_to_reach_admire_item: :registered,
        disable_walk_to_admire_item: :registered
      ],
      fn self ->
        if offhand(self) != nil do
          {false, self}
        else
          self =
            case Brain.get(self, :time_trying_to_reach_admire_item) do
              nil ->
                Brain.set(self, :time_trying_to_reach_admire_item, 0)

              time when time > most ->
                self
                |> Brain.erase(:admiring_item)
                |> Brain.erase(:time_trying_to_reach_admire_item)
                |> Brain.set(:disable_walk_to_admire_item, true, disable)

              time ->
                Brain.set(self, :time_trying_to_reach_admire_item, time + 1)
            end

          {true, self}
        end
      end
    )
  end

  # `PiglinAi.stopHoldingOffHandItem(level, body, true)` for an adult: a
  # gold ingot is its barter (VMC-043d): the bartering table rolled
  # (`getBarterResponseItems`) and thrown; another loved item it drops
  # (wearing it or keeping it in its inventory is still to come).
  defp stop_holding_offhand(self) do
    stack = offhand(self)
    self = %{self | mob: %{self.mob | equipment: Map.delete(self.mob.equipment, :offhand)}}

    if stack.item_id == @gold_ingot do
      {seed, world} = World.loot_seed(self.world)
      {:ok, items} = Valimc.Blocks.Loot.barter(seed)
      throw_items(%{self | world: world}, items)
    else
      Self.effect(self, {:drop, stack})
    end
  end

  # `throwItems`: toward the nearest visible player, else `getRandomNearbyPos`
  # (drawn even with nothing to throw); an off-hand swing, then each item.
  defp throw_items(self, items) do
    {target, self} = throw_target(self)

    if items == [] do
      self
    else
      self = Self.swing(self, :off_hand)

      Enum.reduce(items, self, fn item, acc ->
        Self.effect(acc, throw_item(self, item, target))
      end)
    end
  end

  defp throw_target(self) do
    case World.entity(self.world, Brain.get(self, :nearest_visible_player)) do
      %{x: x, y: y, z: z} ->
        {{x, y, z}, self}

      nil ->
        case Valimc.AI.RandomPos.land(self, 4, 2) do
          {nil, self} -> {{self.x, self.y, self.z}, self}
          found -> found
        end
    end
  end

  # `BehaviorUtils.throwItem` toward a block above `target`: from the hand
  # (0.3 below the eyes), at 0.3 a tick.
  @hand Valimc.Data.Float32.round(0.3)
  defp throw_item(self, stack, {tx, ty, tz}) do
    {dx, dy, dz} =
      Valimc.Entity.Projectile.normalize({tx - self.x, ty + 1.0 - self.y, tz - self.z})

    {:throw, stack, {self.x, Self.eye_y(self) - @hand, self.z},
     {dx * @hand, dy * @hand, dz * @hand}}
  end

  ## Activities and sounds

  @doc """
  `PiglinAi.updateActivity` after the brain's tick: the first valid of its
  activities, its activity sound when it changed, its aggression and its
  dance.
  """
  def update_activity(self) do
    old = Brain.activity(self)
    self = Brain.first_valid(self, [:admire_item, :fight, :avoid, :celebrate, :ride, :idle])

    self =
      if Brain.activity(self) != old,
        do: Valimc.AI.make_sound(self, activity_sound(self)),
        else: self

    # A brain mob's target is its attack target (`getTargetFromBrain`).
    self =
      self
      |> Self.set_aggressive(Brain.has?(self, :attack_target))
      |> Self.put_target(Brain.get(self, :attack_target))

    self =
      if Brain.has?(self, :celebrate_location), do: self, else: Brain.erase(self, :dancing)

    %{self | data: Map.put(self.data, :dancing, Brain.has?(self, :dancing))}
  end

  @doc "`PiglinAi.getSoundForCurrentActivity`."
  def activity_sound(self) do
    case Brain.activity(self) do
      :fight ->
        "minecraft:entity.piglin.angry"

      :avoid ->
        if near_avoid_target?(self), do: "minecraft:entity.piglin.retreat", else: idle_sound(self)

      :admire_item ->
        "minecraft:entity.piglin.admiring_item"

      :celebrate ->
        "minecraft:entity.piglin.celebrate"

      _ ->
        idle_sound(self)
    end
  end

  defp idle_sound(self) do
    cond do
      Brain.has?(self, :nearest_player_holding_wanted_item) -> "minecraft:entity.piglin.jealous"
      Brain.has?(self, :nearest_repellent) -> "minecraft:entity.piglin.retreat"
      true -> "minecraft:entity.piglin.ambient"
    end
  end

  defp near_avoid_target?(self) do
    case World.entity(self.world, Brain.get(self, :avoid_target)) do
      nil -> false
      e -> World.distance_sq(self, e) < 144.0
    end
  end

  @doc "`AbstractPiglin.playAmbientSound`: only an idle piglin's."
  def ambient_sound(self), do: if(Brain.active?(self, :idle), do: activity_sound(self))

  ## Items

  @doc "`Piglin.wantsToPickUp` of a sensed item (mob griefing, `PiglinAi.wantsToPickup`)."
  def wants?(self, %{item: item}) do
    cond do
      not self.world.mob_griefing -> false
      MapSet.member?(@repellents, item) -> false
      Brain.has?(self, :admiring_disabled) and Brain.has?(self, :attack_target) -> false
      item == @gold_ingot -> not_holding_loved?(self)
      # Food, nuggets and gear go to its inventory, which is VMC-043d's.
      MapSet.member?(@food, item) -> false
      loved?(item) -> not_holding_loved?(self)
      true -> false
    end
  end

  @doc """
  `Mob.aiStep`'s looting after the move: each wanted item within a block of
  its box is picked up (`PiglinAi.pickUpItem`): one into its off hand, which
  it then admires.
  """
  def pick_up(%Self{world: world} = self) do
    box = World.inflate(Self.box(self), 1.0, 0.0, 1.0)

    Enum.reduce(world.items, self, fn item, self ->
      if item.count > 0 and item.pickup_delay == 0 and World.intersects?(World.box(item), box) and
           wants?(self, item) do
        take(self, item)
      else
        self
      end
    end)
  end

  defp take(self, item) do
    self = self |> Brain.erase(:walk_target) |> Navigation.stop()
    self = Self.effect(self, {:pickup, World.ref(item), 1})
    stack = %Valimc.Protocol.ItemStack{item_id: item.item, count: 1, components: item.components}

    self =
      case offhand(self) do
        nil -> self
        old -> Self.effect(self, {:drop, old})
      end

    self
    |> Brain.erase(:time_trying_to_reach_admire_item)
    |> then(&%{&1 | mob: %{&1.mob | equipment: Map.put(&1.mob.equipment, :offhand, stack)}})
    |> Brain.set(:admiring_item, true, @admire)
    |> remove_item(item)
  end

  # The item has one less for the mobs after this one.
  defp remove_item(%Self{world: world} = self, item) do
    items =
      for i <- world.items do
        if i.uuid == item.uuid, do: %{i | count: i.count - 1}, else: i
      end

    %{self | world: %{world | items: items}}
  end

  defmodule Sensor do
    @moduledoc """
    `PiglinSpecificSensor`: from what it sees, the first of each kind in
    order of distance (a nemesis, a huntable and a baby hoglin, a zombified
    one, a player wearing no gold it can attack, a player holding what it
    loves), the adult piglins it sees and their count, the adult hoglins it
    sees, the adult piglins near it, and the nearest soul fire (or lit soul
    campfire, torch, lantern) eight blocks around and four up and down, in
    vanilla's Manhattan order.
    """
    alias Valimc.AI.{Brain, Sensors, World}
    alias Valimc.AI.Brains.Piglin

    @repellents for id <-
                      Valimc.Protocol.Data.tags()["minecraft:block"][
                        "minecraft:piglin_repellents"
                      ],
                    name = Valimc.Data.Blocks.name(id),
                    state <- Valimc.Data.Blocks.states(name),
                    name != "soul_campfire" or
                      List.keyfind(Valimc.Data.Blocks.properties(state), "lit", 0) ==
                        {"lit", "true"},
                    into: MapSet.new(),
                    do: state

    def scan(self) do
      self = Brain.set(self, :nearest_repellent, Sensors.repellent(self, @repellents))
      {visible, self} = Sensors.visible_all(self)
      found = Enum.reduce(visible, %{adults: [], hoglins: 0}, &sort(&1, &2, self))
      adults = Enum.reverse(found.adults)

      nearby =
        for ref <- Brain.get(self, :nearest_living_entities) || [],
            %{kind: :mob, type: type} = m <- [World.entity(self.world, ref)],
            type in ["minecraft:piglin", "minecraft:piglin_brute"],
            not Map.get(m, :baby, false),
            do: World.ref(m)

      self
      |> Brain.set(:nearest_visible_nemesis, World.ref(found[:nemesis]))
      |> Brain.set(:nearest_visible_huntable_hoglin, World.ref(found[:huntable]))
      |> Brain.set(:nearest_visible_baby_hoglin, World.ref(found[:baby_hoglin]))
      |> Brain.set(:nearest_visible_zombified, World.ref(found[:zombified]))
      |> Brain.set(:nearest_targetable_player_not_wearing_gold, World.ref(found[:not_gold]))
      |> Brain.set(:nearest_player_holding_wanted_item, World.ref(found[:holding]))
      |> Brain.set(:nearby_adult_piglins, nearby)
      |> Brain.set(:nearest_visible_adult_piglins, Enum.map(adults, &World.ref/1))
      |> Brain.set(:visible_adult_piglin_count, length(adults))
      |> Brain.set(:visible_adult_hoglin_count, found.hoglins)
    end

    defp sort(%{kind: :player} = p, found, self) do
      found =
        if found[:not_gold] == nil and not Piglin.safe_armor?(p) and World.can_attack?(self, p),
          do: Map.put(found, :not_gold, p),
          else: found

      if found[:holding] == nil and p.mode != :spectator and Piglin.holding_loved?(p),
        do: Map.put(found, :holding, p),
        else: found
    end

    defp sort(%{type: "minecraft:hoglin"} = h, found, _self) do
      cond do
        Map.get(h, :baby, false) ->
          Map.put_new(found, :baby_hoglin, h)

        true ->
          found = %{found | hoglins: found.hoglins + 1}
          if Map.get(h, :huntable, true), do: Map.put_new(found, :huntable, h), else: found
      end
    end

    defp sort(%{type: "minecraft:piglin_brute"} = p, found, _self),
      do: %{found | adults: [p | found.adults]}

    defp sort(%{type: "minecraft:piglin"} = p, found, _self) do
      if Map.get(p, :baby, false),
        do: Map.put_new(found, :baby_piglin, p),
        else: %{found | adults: [p | found.adults]}
    end

    defp sort(%{type: type} = m, found, _self)
         when type in ["minecraft:wither_skeleton", "minecraft:wither"] do
      if found[:nemesis] == nil,
        do: Map.put(found, :nemesis, m),
        else: zombified(m, found)
    end

    defp sort(m, found, _self), do: zombified(m, found)

    defp zombified(%{type: type} = m, found)
         when type in ["minecraft:zombified_piglin", "minecraft:zoglin"],
         do: Map.put_new(found, :zombified, m)

    defp zombified(_m, found), do: found
  end
end
