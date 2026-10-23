defmodule Valimc.AI.Mobs.Witch do
  @moduledoc """
  Witches (VMC-043b6), as vanilla's `Witch`:

  - **Goals**: a raider's (patrols, banners, raids and celebrations, idle
    without raids, VMC-047's), floating, throwing potions at its target
    (`RangedAttackGoal`, every three seconds within ten blocks), wandering
    and looking around; whoever hurt it (not a raider), raiders to heal
    (none without a raid) and players as targets.
  - **Drinking** (`aiStep`): not drinking, by chance it drinks water
    breathing with its eyes in water, fire resistance burning, healing
    hurt, or swiftness after a far target; the potion in its hand, slowed
    for 32 ticks, then its effects. Now and then it shows its particles
    (entity event 15).
  - **Throwing** (`performRangedAttack`): slowness at a far target without
    it, poison at a healthy one without it, weakness now and then close by,
    else harming, as a splash potion (`{:throw_potion, ...}`).
  - **Hurts**: magic it resists takes 15% (`witch_resistant_to`).
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI.{Goals, Self, World}
  alias Valimc.Data.{EffectTypes, Float32, PotionTypes}
  alias Valimc.Protocol.ItemStack

  @witch "minecraft:witch"
  @speed "minecraft:movement_speed"
  @drinking "minecraft:drinking"
  @raiders Valimc.Protocol.Data.tags()["minecraft:entity_type"]["minecraft:raiders"]
           |> Enum.map(&Valimc.Data.EntityTypes.name/1)

  @water_breathing EffectTypes.id("water_breathing")
  @fire_resistance EffectTypes.id("fire_resistance")
  @swiftness EffectTypes.id("speed")
  @slowness EffectTypes.id("slowness")
  @poison EffectTypes.id("poison")
  @weakness EffectTypes.id("weakness")

  @impl true
  def types, do: [@witch]

  @impl true
  def goals(_type) do
    idle = fn name -> Goals.Idle.new(name) end

    {[
       {4, "LongDistancePatrolGoal", Goals.Idle, [:move], idle.("LongDistancePatrolGoal")},
       {1, "ObtainRaidLeaderBannerGoal", Goals.Idle, [:move],
        idle.("ObtainRaidLeaderBannerGoal")},
       {3, "PathfindToRaidGoal", Goals.Idle, [:move], idle.("PathfindToRaidGoal")},
       {4, "RaiderMoveThroughVillageGoal", Goals.Idle, [:move],
        idle.("RaiderMoveThroughVillageGoal")},
       {5, "RaiderCelebration", Goals.Idle, [:move], idle.("RaiderCelebration")},
       {1, "FloatGoal", Goals.Float, [:jump], %{}},
       {2, "RangedAttackGoal", Goals.RangedAttack, [:move, :look],
        Goals.RangedAttack.new(1.0, 60, 60, 10.0, &throw/3)},
       {2, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)},
       {3, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {3, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(ignore: @raiders)},
       {2, "NearestHealableRaiderTargetGoal", __MODULE__.HealRaiders, [:target], %{}},
       {3, "NearestAttackableWitchTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true, interval: 10)}
     ]}
  end

  @impl true
  def data(_type), do: %{drinking: false, using_time: 0, heal_cooldown: 0}

  @impl true
  def values(%{data: data}), do: [{:witch_using_item, data.drinking, false}]

  @doc """
  `PatrollingMonster.finalizeSpawn`: outside patrols, events and structures
  the level draws whether it leads a patrol, which a witch never does; then
  a mob's.
  """
  @impl true
  def finalize(self, reason) do
    self =
      if reason in [:patrol, :event, :structure],
        do: self,
        else: elem(Valimc.AI.Spawn.level_float(self), 1)

    Valimc.AI.Spawn.mob(self, reason)
  end

  ## Hurts

  @doc """
  `getDamageAfterMagicAbsorb`: magic it resists takes 15% (its armor is
  none, so before or after armor is the same).
  """
  @impl true
  def taken(_body, %{source: source, amount: amount} = hit) do
    type = Valimc.Living.DamageSource.type(source)

    if Valimc.Protocol.DamageTypes.tag?(type, :witch_resistant_to),
      do: %{hit | amount: Float32.round(amount * Float32.round(0.15))},
      else: hit
  end

  ## Drinking

  @doc "`aiStep` before its super: the raider heal cooldown, drinking, its particles."
  @impl true
  def before_ai(%Self{data: data} = self) do
    if Valimc.Entity.Mob.alive?(self.mob) do
      self = %{self | data: %{data | heal_cooldown: data.heal_cooldown - 1}}
      self = if self.data.drinking, do: drink(self), else: maybe_drink(self)
      {f, self} = Self.float(self)
      if f < Float32.round(7.5e-4), do: Self.effect(self, {:event, 15}), else: self
    else
      self
    end
  end

  defp drink(%Self{data: data} = self) do
    if data.using_time <= 0 do
      stack = self.mob.equipment[:mainhand]
      mob = %{self.mob | equipment: Map.delete(self.mob.equipment, :mainhand)}

      mob =
        case stack && potion(stack) do
          nil ->
            mob

          id ->
            Enum.reduce(PotionTypes.effects(id), mob, fn {effect, [rung | _]}, mob ->
              Valimc.Entity.Mob.add_effect(mob, effect, rung)
            end)
        end

      %{self | mob: mob, data: %{data | drinking: false, using_time: data.using_time - 1}}
      |> modify(false)
    else
      %{self | data: %{data | using_time: data.using_time - 1}}
    end
  end

  defp potion(%ItemStack{item_id: item, components: components}) do
    if item == Valimc.Protocol.ItemTypes.id("potion"),
      do: get_in(components, ["minecraft:potion_contents", :potion])
  end

  defp maybe_drink(self) do
    {potion, self} = choose(self)

    if potion == nil do
      self
    else
      stack = potion_stack("potion", potion)
      {f, self} = Self.float(self)
      pitch = Float32.round(Float32.round(0.8) + Float32.round(f * Float32.round(0.4)))
      source = Valimc.Protocol.CombatPackets.mob_sounds(@witch)["sound_source"]
      sound = Valimc.AI.Facts.sound_id("minecraft:entity.witch.drink")
      equipment = Map.put(self.mob.equipment, :mainhand, stack)

      %{self | mob: %{self.mob | equipment: equipment}}
      |> then(&%{&1 | data: %{&1.data | drinking: true, using_time: 32}})
      |> Self.effect({:sound_at, sound, source, {self.x, self.y, self.z}, 1.0, pitch})
      |> modify(true)
    end
  end

  # Each chance is drawn only as the ones before it fail.
  defp choose(self) do
    has = fn id -> Map.has_key?(self.mob.living.effects, id) end
    target = World.target(self)

    checks = [
      {0.15, fn -> eyes_in_water?(self) and not has.(@water_breathing) end, "water_breathing"},
      {0.15, fn -> burning?(self) and not has.(@fire_resistance) end, "fire_resistance"},
      {0.05, fn -> hurt?(self) end, "healing"},
      {0.5,
       fn ->
         target != nil and not has.(@swiftness) and World.distance_sq(self, target) > 121.0
       end, "swiftness"}
    ]

    Enum.reduce_while(checks, {nil, self}, fn {chance, test, potion}, {nil, self} ->
      {f, self} = Self.float(self)

      if f < Float32.round(chance) and test.(),
        do: {:halt, {potion, self}},
        else: {:cont, {nil, self}}
    end)
  end

  defp eyes_in_water?(self), do: self.mob.motion.eye_water

  # On fire, or its last damage (within two seconds, `getLastDamageSource`)
  # was fire's.
  defp burning?(self) do
    self.mob.living.fire_ticks > 0 or
      case self.mind.damage do
        {type, at, _} when is_atom(type) ->
          self.mind.tick - at <= 40 and Valimc.Protocol.DamageTypes.tag?(type, :is_fire)

        _ ->
          false
      end
  end

  defp hurt?(self),
    do:
      self.mob.living.health.value <
        Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:max_health")

  # The drinking modifier: -0.25 movement speed.
  defp modify(%Self{mob: mob} = self, on) do
    instance = Map.get(mob.attributes, @speed, %{base: nil, modifiers: []})
    rest = Enum.reject(instance.modifiers, &(elem(&1, 0) == @drinking))
    modifiers = if on, do: rest ++ [{@drinking, -0.25, 0}], else: rest

    attributes =
      if modifiers == [] and instance.base == nil,
        do: Map.delete(mob.attributes, @speed),
        else: Map.put(mob.attributes, @speed, %{instance | modifiers: modifiers})

    %{self | mob: %{mob | attributes: attributes}}
  end

  defp potion_stack(item, potion) do
    contents = %{Valimc.Protocol.PotionContents.empty() | potion: PotionTypes.id(potion)}
    %{ItemStack.new(item) | components: %{"minecraft:potion_contents" => contents}}
  end

  ## Throwing

  @doc """
  `performRangedAttack` (not while drinking): the potion for the target,
  thrown from its eyes toward where the target is heading, and its sound.
  """
  def throw(%Self{data: %{drinking: true}} = self, _target, _power), do: self

  def throw(%Self{} = self, target, _power) do
    {vx, _, vz} = Map.get(target, :velocity, {0.0, 0.0, 0.0})
    xd = target.x + vx - self.x
    yd = World.eye_y(target) - Float32.round(1.1) - self.y
    zd = target.z + vz - self.z
    dist = :math.sqrt(xd * xd + zd * zd)
    effects = Map.get(target, :effects, MapSet.new())
    health = Map.get(target, :health, 20.0)

    {potion, self} =
      cond do
        dist >= 8.0 and not MapSet.member?(effects, @slowness) ->
          {"slowness", self}

        health >= 8.0 and not MapSet.member?(effects, @poison) ->
          {"poison", self}

        dist <= 3.0 and not MapSet.member?(effects, @weakness) ->
          {f, self} = Self.float(self)
          {if(f < Float32.round(0.25), do: "weakness", else: "harming"), self}

        true ->
          {"harming", self}
      end

    {f, self} = Self.float(self)
    pitch = Float32.round(Float32.round(0.8) + Float32.round(f * Float32.round(0.4)))
    source = Valimc.Protocol.CombatPackets.mob_sounds(@witch)["sound_source"]
    sound = Valimc.AI.Facts.sound_id("minecraft:entity.witch.throw")

    self
    |> Self.effect(
      {:throw_potion,
       %{
         stack: potion_stack("splash_potion", potion),
         from: {self.x, Self.eye_y(self) - 0.10000000149011612, self.z},
         direction: {xd, yd + dist * Float32.round(0.2), zd},
         velocity: if(dist <= 2.0, do: 0.45, else: 0.75),
         uncertainty: 8.0
       }}
    )
    |> Self.effect({:sound_at, sound, source, {self.x, self.y, self.z}, 1.0, pitch})
  end
end

defmodule Valimc.AI.Mobs.Witch.HealRaiders do
  @moduledoc """
  `NearestHealableRaiderTargetGoal`: off its cooldown it flips a coin each
  update; without a raid it finds no raider to heal (raids are VMC-047's).
  """
  use Valimc.AI.Goal

  def can_use(state, self) do
    if self.data.heal_cooldown > 0 do
      {false, state, self}
    else
      {_heads, self} = Self.boolean(self)
      {false, state, self}
    end
  end
end
