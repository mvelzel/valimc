defmodule Valimc.AI.Mobs.ZombifiedPiglin do
  @moduledoc """
  A zombified piglin (VMC-043d, vanilla's `ZombifiedPiglin`): a zombie's
  goals with its own behaviour goals, and a neutral mob's anger
  (`Valimc.AI.Neutral`). Hurt, it targets its attacker and its kind around
  it join; it stays angry for 20 to 39 seconds, faster while angry (the
  `minecraft:attacking` speed modifier), growls once a second or less after
  it first finds a target, and every four to six seconds alerts the others
  that have no target, while it sees its own.

  It spawns as a zombie does, with a golden sword (`finalize/2`). Its own
  mind fields (`Mind.own`): the neutral fields, the ticks to its first
  anger sound and to its next alert.
  """
  alias Valimc.AI
  alias Valimc.AI.{Goals, Neutral, Self, Spawn, World}
  alias Valimc.AI.Mobs.Zombie
  alias Valimc.Data.Float32
  alias Valimc.Protocol.ItemStack

  @type_name "minecraft:zombified_piglin"
  @anger {400, 780}
  @attacking "minecraft:attacking"
  @speed "minecraft:movement_speed"
  @angry_sound "minecraft:entity.zombified_piglin.angry"
  @turtle_eggs Enum.to_list(Valimc.Data.Blocks.states("turtle_egg"))

  @doc "The family's types (`Valimc.AI.Mobs`)."
  @behaviour Valimc.AI.Kind

  @impl true
  def types, do: [@type_name]

  @doc "The goals a zombified piglin registers (a zombie's, with its own behaviour goals)."
  @impl true
  def goals(_type), do: registered()

  @doc "A zombie's own data (`Zombie.data/1`): the baby flag and the rest."
  @impl true
  def data(_type), do: Zombie.data("minecraft:zombie")

  @doc "A zombie's entity data values."
  @impl true
  def values(body), do: Zombie.values(body)

  @doc "A baby's dimensions, or nil."
  @impl true
  def dimensions(body), do: Zombie.dimensions(body)

  @doc """
  `finalizeSpawn`: a zombie's (babies, jockeys, door breaking, a Halloween
  head, its knockback and follow range bonuses), but a golden sword in hand,
  one time in twenty a golden spear, and no armour
  (`populateDefaultEquipmentSlots`), and no reinforcements
  (`randomizeReinforcementsChance`).
  """
  @impl true
  def finalize(self, reason),
    do: Zombie.zombie(self, reason, populate: &golden/1, reinforcements: false)

  defp golden(self) do
    {n, self} = Spawn.level_int(self, 20)

    Spawn.equip(
      self,
      :mainhand,
      ItemStack.new(if n == 0, do: "golden_spear", else: "golden_sword")
    )
  end

  def registered do
    {[
       {4, "ZombieAttackTurtleEggGoal", Goals.RemoveBlock, [:move, :jump],
        Goals.RemoveBlock.new(@turtle_eggs)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       {1, "SpearUseGoal", Goals.Idle, [:move, :look], Goals.Idle.new("SpearUseGoal")},
       {2, "ZombieAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, false, raise_arms: true)},
       {7, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, alert_types: [@type_name])},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true,
          interval: 10,
          selector: &Neutral.angry_at?(&2, &1)
        )},
       {3, "ResetUniversalAngerTargetGoal", Goals.ResetUniversalAnger, [],
        Goals.ResetUniversalAnger.new(@anger)}
     ]}
  end

  @doc "A fresh zombified piglin's own fields."
  def own, do: Map.merge(Neutral.fields(), %{first_sound: 0, next_alert: 0})

  defp ensure(%Self{mind: %{own: nil}} = self), do: Self.mind(self, &%{&1 | own: own()})
  defp ensure(self), do: self

  defp put(self, changes), do: Self.mind(self, &%{&1 | own: Map.merge(&1.own, changes)})

  @doc """
  `setTarget`: a first target draws the delays to its first anger sound
  (0 to 20 ticks) and its first alert (80 to 120).
  """
  @impl true
  def set_target(%Self{} = self, target) do
    self = ensure(self)

    self =
      if World.target(self) == nil and target != nil do
        {sound, self} = Self.int(self, 21)
        {alert, self} = Self.int(self, 41)
        put(self, %{first_sound: sound, next_alert: 80 + alert})
      else
        self
      end

    Self.put_target(self, target)
  end

  @doc "`getAmbientSound`: angry or not."
  @impl true
  def ambient_sound(%Self{facts: facts} = self) do
    if Neutral.angry?(ensure(self)), do: @angry_sound, else: facts.ambient_sound
  end

  @doc """
  `customServerAiStep`: the attacking speed while angry and its first
  growl, the anger kept up to date (`updatePersistentAnger`, staying angry
  while it has a target), and alerts while it has a target.
  """
  @impl true
  def custom_step(%Self{} = self) do
    self = ensure(self)
    modified = attacking?(self.mob)

    self =
      cond do
        Neutral.angry?(self) ->
          self = if modified, do: self, else: modify(self, true)
          growl(self)

        modified ->
          modify(self, false)

        true ->
          self
      end

    self = Neutral.update(self, true, @anger)
    if World.target(self) != nil, do: maybe_alert(self), else: self
  end

  defp attacking?(mob),
    do:
      Enum.any?(get_in(mob.attributes, [@speed, :modifiers]) || [], &(elem(&1, 0) == @attacking))

  # The `attacking` modifier's +0.05 movement speed on or off.
  defp modify(%Self{mob: mob} = self, on) do
    instance = Map.get(mob.attributes, @speed, %{base: nil, modifiers: []})
    rest = Enum.reject(instance.modifiers, &(elem(&1, 0) == @attacking))
    modifiers = if on, do: rest ++ [{@attacking, 0.05, 0}], else: rest

    attributes =
      if modifiers == [] and instance.base == nil,
        do: Map.delete(mob.attributes, @speed),
        else: Map.put(mob.attributes, @speed, %{instance | modifiers: modifiers})

    %{self | mob: %{mob | attributes: attributes}}
  end

  # `maybePlayFirstAngerSound`: twice as loud, pitched up 1.8 times.
  defp growl(%Self{mind: %{own: %{first_sound: n}}} = self) when n > 0 do
    self = put(self, %{first_sound: n - 1})

    if n - 1 == 0 do
      {pitch, mind} = AI.voice(self.mind, nil)
      self = %{self | mind: mind}
      <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

      Self.effect(
        self,
        {:sound, AI.Facts.sound_id(@angry_sound), source(),
         Float32.round(self.facts.volume * 2.0), Float32.round(pitch * Float32.round(1.8)), seed}
      )
    else
      self
    end
  end

  defp growl(self), do: self

  defp source, do: Valimc.Protocol.CombatPackets.mob_sounds(@type_name)["sound_source"]

  # `maybeAlertOthers`.
  defp maybe_alert(%Self{mind: %{own: %{next_alert: n}}} = self) when n > 0,
    do: put(self, %{next_alert: n - 1})

  defp maybe_alert(self) do
    target = World.target(self)
    {seen, self} = World.sees?(self, target)
    self = if seen, do: alert_others(self, target), else: self
    {n, self} = Self.int(self, 41)
    put(self, %{next_alert: 80 + n})
  end

  # `alertOthers`: its kind within its follow range (ten blocks up and down)
  # that have no target take its own.
  defp alert_others(self, target) do
    within = Goals.Target.follow(self)

    box =
      {self.x - within, self.y - 10.0, self.z - within, self.x + 1.0 + within,
       self.y + 1.0 + 10.0, self.z + 1.0 + within}

    self
    |> World.mobs_in([@type_name], box)
    |> Enum.reduce(self, fn other, self ->
      if other.uuid != self.uuid and World.entity(self.world, other.target) == nil,
        do: Self.effect(self, {:alert, other.uuid, World.ref(target)}),
        else: self
    end)
  end
end
