defmodule Valimc.AI.Brains.Hoglin do
  @moduledoc """
  A hoglin's brain (VMC-043d, `HoglinAi`): its sensors and its core, idle,
  fight and retreat activities with vanilla's behaviours in vanilla's order.

  - **Core:** the look and walk sinks.
  - **Idle:** pacified by a warped fungus (or a portal, a respawn anchor)
    near it; walk away from it; attack the nearest player it may attack;
    an adult walks away from the adult piglins it sees; looks at what is
    near now and then; a baby follows an adult; a random stroll, walking to
    what it looks at, or nothing (one at random).
  - **Fight:** pacified as in idle; walk to its target; an adult's melee
    every 40 ticks, a baby's every 15; drop an invalid target.
  - **Retreat:** walk away from what it avoids, idle movement and looks;
    an adult stops once piglins no longer outnumber the hoglins it sees.

  Hurt, it gives up its peace; a baby flees the attacker, an adult turns on
  it (not on another hoglin, nor a piglin while retreating) with the adult
  hoglins it sees. Its hit on a piglin while piglins outnumber them sends
  them all fleeing, else they join the attack. Breeding (`AnimalMakeLove`)
  waits for hoglin feeding.
  """
  alias Valimc.AI.{Behavior, Behaviors, Brain, Random, Self, Sensors, World}
  alias Valimc.AI.Behaviors.Fight

  @hoglin "minecraft:hoglin"

  @sensors [
    {Sensors.NearestLiving, 20},
    {Sensors.Players, 20},
    {Sensors.NearestAdult, 20},
    {__MODULE__.Sensor, 20}
  ]

  @doc """
  A hoglin's brain, its sensors' countdowns drawn from the mob's `random`
  and its two `RunOne`s shuffled by `gates` (the retreat's and the idle
  movement's randoms): `{brain, random}`.
  """
  def brain(random, [avoid_gate, idle_gate]) do
    core = [Behaviors.look_sink(45, 90), Behaviors.move_sink()]

    idle = [
      Behaviors.become_passive(:nearest_repellent, 200),
      Behavior.inert("AnimalMakeLove"),
      Fight.walk_away(:nearest_repellent, :pos, 1.0, 8, true),
      Fight.start_attacking(fn _ -> true end, &find_target/1),
      Behaviors.trigger_if(
        &adult?/1,
        Fight.walk_away(:nearest_visible_adult_piglin, :entity, 0.4, 8, false)
      ),
      Behaviors.look_sometimes(fn _ -> true end, 8.0, {30, 60}),
      Behaviors.baby_follow_adult({5, 16}, 0.6),
      idle_movement(idle_gate)
    ]

    fight = [
      Behaviors.become_passive(:nearest_repellent, 200),
      Behavior.inert("AnimalMakeLove"),
      Fight.walk_to_target(1.0),
      Fight.melee(&adult?/1, 40),
      Fight.melee(&(not adult?(&1)), 15),
      Fight.stop_if_invalid(),
      Fight.erase_if(&breeding?/1, :attack_target)
    ]

    avoid = [
      Fight.walk_away(:avoid_target, :entity, 1.3, 15, false),
      idle_movement(avoid_gate),
      Behaviors.look_sometimes(fn _ -> true end, 8.0, {30, 60}),
      Fight.erase_if(&wants_to_stop_fleeing?/1, :avoid_target)
    ]

    Brain.new(
      __MODULE__,
      @sensors,
      [
        {:core, 0, core, [], []},
        {:idle, 10, idle, [], []},
        {:fight, 10, fight, [attack_target: :present], [:attack_target]},
        {:avoid, 10, avoid, [avoid_target: :present], [:avoid_target]}
      ],
      random
    )
  end

  defp idle_movement(gate),
    do:
      Behavior.run_one(
        [
          {Behaviors.stroll(0.4), 2},
          {Behaviors.walk_to_look_target(fn _ -> true end, 0.4, 3), 2},
          {Behavior.do_nothing(30, 60), 1}
        ],
        gate
      )

  @doc "The seeds of a fresh hoglin's two `RunOne` randoms, from its uuid."
  def gates(<<a::64, b::64>>),
    do:
      for(
        salt <- [0x6B1D, 0x2E59],
        do: Random.new(Bitwise.bxor(Bitwise.bxor(a, b * salt), salt))
      )

  @doc "Whether the hoglin is an adult (`isAdult`)."
  def adult?(%Self{data: data}), do: data.age >= 0

  defp breeding?(self), do: Brain.has?(self, :breed_target)
  defp pacified?(self), do: Brain.has?(self, :pacified)

  # `findNearestValidAttackTarget`: the nearest player it may attack, unless
  # pacified or breeding.
  defp find_target(self) do
    if pacified?(self) or breeding?(self),
      do: {nil, self},
      else: {World.entity(self.world, Brain.get(self, :nearest_visible_attackable_player)), self}
  end

  defp wants_to_stop_fleeing?(self), do: adult?(self) and not piglins_outnumber?(self)

  # `piglinsOutnumberHoglins`: more adult piglins seen than adult hoglins
  # (itself among them).
  defp piglins_outnumber?(self) do
    adult?(self) and
      (Brain.get(self, :visible_adult_piglin_count) || 0) >
        (Brain.get(self, :visible_adult_hoglin_count) || 0) + 1
  end

  ## Reactions

  @doc "What another mob or a hurt asks of it before it thinks."
  def react(self, {:hurt_by, ref}) do
    case World.entity(self.world, ref) do
      nil -> self
      attacker -> hurt_by(self, attacker)
    end
  end

  def react(self, _event), do: self

  @doc """
  `HoglinAi.wasHurtBy`: no longer pacified or breeding; a baby flees the
  nearest of the attacker and what it avoids or attacks; an adult may
  retaliate.
  """
  def hurt_by(%Self{} = self, attacker) do
    self = self |> Brain.erase(:pacified) |> Brain.erase(:breed_target)

    if adult?(self),
      do: retaliate(self, attacker),
      else: retreat_from_nearest(self, World.ref(attacker))
  end

  # `maybeRetaliate`: not at a piglin while retreating, nor at a hoglin, nor
  # at one much farther than its target; at one it may attack, with the
  # adult hoglins it sees.
  defp retaliate(self, attacker) do
    cond do
      Brain.active?(self, :avoid) and Map.get(attacker, :type) == "minecraft:piglin" ->
        self

      Map.get(attacker, :type) == @hoglin ->
        self

      Fight.much_farther?(self, attacker, 4.0) ->
        self

      true ->
        case Sensors.attackable?(self, attacker) do
          {true, self} -> self |> set_attack_target(attacker) |> broadcast_attack(attacker)
          {false, self} -> self
        end
    end
  end

  # `setAttackTarget`: for ten seconds.
  defp set_attack_target(self, target) do
    self
    |> Brain.erase(:cant_reach_walk_target_since)
    |> Brain.erase(:breed_target)
    |> Brain.set(:attack_target, World.ref(target), 200)
  end

  # `broadcastAttackTarget`: each adult hoglin it sees attacks the nearer of
  # its target and this.
  defp broadcast_attack(self, target) do
    ref = World.ref(target)

    (Brain.get(self, :nearest_visible_adult_hoglins) || [])
    |> Enum.reduce(self, fn {:mob, uuid}, self ->
      Self.effect(self, {:brain, uuid, &attack_if_closer(&1, ref)})
    end)
  end

  defp attack_if_closer(self, ref) do
    case World.entity(self.world, ref) do
      nil ->
        self

      new ->
        current = World.entity(self.world, Brain.get(self, :attack_target))
        if pacified?(self), do: self, else: set_attack_target(self, nearest(self, current, new))
    end
  end

  # `BehaviorUtils.getNearestTarget`: what it has if nearer, else the new one.
  defp nearest(_self, nil, new), do: new

  defp nearest(self, current, new),
    do:
      if(World.distance_sq(self, current) < World.distance_sq(self, new), do: current, else: new)

  # `broadcastRetreat`: each adult hoglin it sees flees the nearest of its threats.
  defp broadcast_retreat(self, target) do
    ref = World.ref(target)

    (Brain.get(self, :nearest_visible_adult_hoglins) || [])
    |> Enum.reduce(self, fn {:mob, uuid}, self ->
      Self.effect(self, {:brain, uuid, &retreat_from_nearest(&1, ref)})
    end)
  end

  # `retreatFromNearestTarget`.
  defp retreat_from_nearest(self, ref) do
    case World.entity(self.world, ref) do
      nil ->
        self

      target ->
        nearest =
          [Brain.get(self, :avoid_target), Brain.get(self, :attack_target)]
          |> Enum.reduce(target, fn ref, nearest ->
            nearest(self, World.entity(self.world, ref), nearest)
          end)

        set_avoid_target(self, nearest)
    end
  end

  # `setAvoidTarget`: for 5 to 20 seconds (the level's random).
  defp set_avoid_target(self, target) do
    {n, self} = Behavior.level_int(self, 301)

    self
    |> Brain.erase(:attack_target)
    |> Brain.erase(:walk_target)
    |> Brain.set(:avoid_target, World.ref(target), 100 + n)
  end

  @doc """
  `HoglinAi.onHitTarget` (its `doHurtTarget`): an adult's hit on a piglin
  while piglins outnumber them sends it and the hoglins it sees fleeing;
  any other hit has them join the attack.
  """
  def on_hit(self, target) do
    cond do
      not adult?(self) ->
        self

      Map.get(target, :type) == "minecraft:piglin" and piglins_outnumber?(self) ->
        self |> set_avoid_target(target) |> broadcast_retreat(target)

      true ->
        broadcast_attack(self, target)
    end
  end

  ## Activities and sounds

  @doc """
  `HoglinAi.updateActivity` after the brain's tick: fight, retreat or idle,
  its activity sound when it changed, and its aggression.
  """
  def update_activity(self) do
    old = Brain.activity(self)
    self = Brain.first_valid(self, [:fight, :avoid, :idle])

    self =
      if Brain.activity(self) != old,
        do: Valimc.AI.make_sound(self, activity_sound(self)),
        else: self

    self
    |> Self.set_aggressive(Brain.has?(self, :attack_target))
    |> Self.put_target(Brain.get(self, :attack_target))
  end

  @doc "`HoglinAi.getSoundForCurrentActivity`."
  def activity_sound(self) do
    case Brain.activity(self) do
      :avoid ->
        "minecraft:entity.hoglin.retreat"

      :fight ->
        "minecraft:entity.hoglin.angry"

      nil ->
        nil

      _ ->
        if Brain.has?(self, :nearest_repellent),
          do: "minecraft:entity.hoglin.retreat",
          else: "minecraft:entity.hoglin.ambient"
    end
  end

  @doc "`Hoglin.getAmbientSound`: its activity's."
  def ambient_sound(self), do: activity_sound(self)

  def pick_up(self), do: self

  defmodule Sensor do
    @moduledoc """
    `HoglinSpecificSensor`: the nearest hoglin repellent eight blocks around
    and four up and down (vanilla's Manhattan order), and of the adult
    piglins and hoglins it sees, the nearest piglin, the piglins' count and
    the hoglins.
    """
    alias Valimc.AI.{Brain, Sensors, World}

    @repellents for id <-
                      Valimc.Protocol.Data.tags()["minecraft:block"][
                        "minecraft:hoglin_repellents"
                      ],
                    name = Valimc.Data.Blocks.name(id),
                    state <- Valimc.Data.Blocks.states(name),
                    into: MapSet.new(),
                    do: state

    def scan(self) do
      self = Brain.set(self, :nearest_repellent, Sensors.repellent(self, @repellents))
      {visible, self} = Sensors.visible_all(self)

      adults =
        Enum.filter(
          visible,
          &(not Map.get(&1, :baby, false) and
              Map.get(&1, :type) in ["minecraft:piglin", "minecraft:hoglin"])
        )

      piglins = Enum.filter(adults, &(&1.type == "minecraft:piglin"))
      hoglins = Enum.filter(adults, &(&1.type == "minecraft:hoglin"))

      self
      |> Brain.set(:nearest_visible_adult_piglin, World.ref(List.first(piglins)))
      |> Brain.set(:nearest_visible_adult_hoglins, Enum.map(hoglins, &World.ref/1))
      |> Brain.set(:visible_adult_piglin_count, length(piglins))
      |> Brain.set(:visible_adult_hoglin_count, length(hoglins))
    end
  end
end
