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
  go: a gold ingot is its barter (VMC-043d's loot), another loved item it
  drops.
  """
  alias Valimc.AI.{Behavior, Behaviors, Brain, Navigation, Random, Self, Sensors, World}
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
    {Sensors.Piglin, 20}
  ]

  @doc """
  A piglin's brain, its sensors' countdowns drawn from the mob's `random`
  (as its constructor draws them) and its two `RunOne`s shuffled by
  `gates` (two randoms): `{brain, random}`.
  """
  def brain(random, [look_gate, move_gate]) do
    core = [
      Behaviors.look_sink(45, 90),
      Behaviors.move_sink(),
      Behavior.inert("InteractWithDoor"),
      Behavior.inert("babyAvoidNemesis"),
      Behavior.inert("avoidZombified"),
      stop_holding(),
      start_admiring(@admire),
      Behavior.inert("StartCelebratingIfTargetDead"),
      Behavior.inert("StopBeingAngryIfTargetDead")
    ]

    idle = [
      Behaviors.look_target(&holding_loved?/1, 14.0),
      Behavior.inert("StartAttacking"),
      Behavior.inert("StartHuntingHoglin"),
      Behavior.inert("avoidRepellent"),
      Behavior.inert("babySometimesRideBabyHoglin"),
      Behavior.run_one(look_behaviors(), look_gate),
      Behavior.run_one(
        [
          {Behaviors.stroll(0.6), 2},
          {Behaviors.interact_with("minecraft:piglin", 8, 0.6, 2), 2},
          {Behaviors.walk_to_look_target(
             &(not Brain.has?(&1, :nearest_player_holding_wanted_item)),
             0.6,
             3
           ), 2},
          {Behavior.do_nothing(30, 60), 1}
        ],
        move_gate
      ),
      Behaviors.look_and_interact(:player, 4)
    ]

    admire = [
      Behaviors.go_to_wanted_item(&not_holding_loved?/1, 1.0, true, 9),
      stop_if_too_far(9),
      stop_if_tired(200, 200)
    ]

    Brain.new(
      __MODULE__,
      @sensors,
      [
        {:core, 0, core, [], []},
        {:idle, 10, idle, [], []},
        {:admire_item, 10, admire, [admiring_item: :present], [:admiring_item]}
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

  @doc "The seeds of a fresh piglin's two `RunOne` randoms, from its uuid."
  def gates(<<a::64, b::64>>),
    do: [Random.new(Bitwise.bxor(a, 0x5A17)), Random.new(Bitwise.bxor(b, 0x9E37))]

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
  # gold ingot is its barter, thrown toward the player it sees or a random
  # spot near it (the loot is VMC-043d's: the spot is drawn even with nothing
  # to throw); another loved item it drops (wearing it or keeping it in its
  # inventory is VMC-043d's).
  defp stop_holding_offhand(self) do
    stack = offhand(self)
    self = %{self | mob: %{self.mob | equipment: Map.delete(self.mob.equipment, :offhand)}}

    if stack.item_id == @gold_ingot do
      {target, self} = throw_target(self)
      Self.effect(self, {:barter, stack, target})
    else
      Self.effect(self, {:drop, stack})
    end
  end

  # `throwItems`: toward the nearest visible player, else `getRandomNearbyPos`.
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

  ## Activities and sounds

  @doc """
  `PiglinAi.updateActivity` after the brain's tick: the first valid of its
  activities, its activity sound when it changed, its aggression.
  """
  def update_activity(self) do
    old = Brain.activity(self)
    self = Brain.first_valid(self, [:admire_item, :idle])

    self =
      if Brain.activity(self) != old,
        do: Valimc.AI.make_sound(self, activity_sound(self)),
        else: self

    self
    |> Self.set_aggressive(Brain.has?(self, :attack_target))
    |> Brain.erase(:dancing)
  end

  @doc "`PiglinAi.getSoundForCurrentActivity`."
  def activity_sound(self) do
    case Brain.activity(self) do
      :admire_item ->
        "minecraft:entity.piglin.admiring_item"

      _ ->
        cond do
          Brain.has?(self, :nearest_player_holding_wanted_item) ->
            "minecraft:entity.piglin.jealous"

          Brain.has?(self, :nearest_repellent) ->
            "minecraft:entity.piglin.retreat"

          true ->
            "minecraft:entity.piglin.ambient"
        end
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
end
