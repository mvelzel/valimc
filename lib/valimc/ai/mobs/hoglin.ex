defmodule Valimc.AI.Mobs.Hoglin do
  @moduledoc """
  A hoglin as a mob family (VMC-043d, vanilla's `Hoglin`): an ageable mob
  (a baby one time in five, smaller, weaker and quicker to strike) with its
  entity data (baby, immune to zombification), its own data (its age, time
  in the overworld, whether piglins may hunt it) and its hit
  (`doHurtTarget`): the attack event and sound, the brain's reaction, then
  `HoglinBase.hurtAndThrowTarget`: an adult hits for half its attack damage
  plus up to as much again and throws what it hits.

  Its brain is `Valimc.AI.Brains.Hoglin`; it registers no goals.
  Zombification outside the Nether and breeding wait (see the ticket).
  """
  @behaviour Valimc.AI.Kind

  alias Valimc.AI.{Behavior, Self, Spawn, World}
  alias Valimc.AI.Brains
  alias Valimc.Data.Float32

  @hoglin "minecraft:hoglin"
  @attack "minecraft:attack_damage"
  @netherite ~w(netherite_helmet netherite_chestplate netherite_leggings netherite_boots)
             |> Enum.map(&Valimc.Protocol.ItemTypes.id("minecraft:" <> &1))

  @impl true
  def types, do: [@hoglin]

  @doc "A brain mob registers no goals."
  @impl true
  def goals(_type), do: {[], []}

  @impl true
  def brain, do: Brains.Hoglin

  @impl true
  def data(_type), do: %{age: 0, immune: false, time_in_overworld: 0, cannot_be_hunted: false}

  @impl true
  def values(%{data: data}),
    do: [{:ageable_baby, data.age < 0, false}, {:hoglin_immune, data.immune, false}]

  @doc "`isBaby`."
  @impl true
  def young?(%{data: data}), do: data.age < 0

  @doc "A baby's dimensions (`BABY_DIMENSIONS`), or nil."
  @impl true
  def dimensions(%{data: %{age: age}}) when age < 0,
    do: {Float32.round(0.75), Float32.round(0.85), Float32.round(0.625)}

  def dimensions(_body), do: nil

  @doc "`getVoicePitch`'s base: a baby's is higher."
  @impl true
  def voice(_type, %{age: age}) when age < 0, do: 1.5
  def voice(_type, _data), do: 1.0

  @impl true
  def experience(%{data: %{age: age}}), do: if(age < 0, do: 3, else: 5)

  @impl true
  def leashable?, do: true

  @doc """
  `Hoglin.finalizeSpawn`: a baby one time in five (the level's random),
  then an ageable mob's (no group yet) and a mob's own spawn.
  """
  @impl true
  def finalize(%Self{} = self, reason) do
    {f, self} = Spawn.level_float(self)
    self = if f < Float32.round(0.2), do: set_baby(self, true), else: self
    Spawn.mob(self, reason)
  end

  @doc "`setBaby` (`ageBoundaryReached`): its age and a baby's attack damage."
  def set_baby(%Self{} = self, baby) do
    self = %{self | data: %{self.data | age: if(baby, do: -24_000, else: 0)}}
    Spawn.set_base(self, @attack, if(baby, do: 0.5, else: 6.0))
  end

  @doc "`AgeableMob.aiStep`: a baby grows up a tick at a time."
  @impl true
  def after_ai(%Self{data: %{age: age}} = self) when age < 0 do
    self = %{self | data: %{self.data | age: age + 1}}
    if age + 1 == 0, do: set_baby(self, false), else: self
  end

  def after_ai(self), do: self

  @doc """
  `Hoglin.doHurtTarget` on `target`: the attack event (4) and sound, the
  brain's reaction (`HoglinAi.onHitTarget`), then the hit's amount and an
  adult's throw from the level's random, for the owner to land.
  """
  @impl true
  def hit(%Self{} = self, target) do
    self =
      self
      |> Self.effect({:event, 4})
      |> Valimc.AI.make_sound("minecraft:entity.hoglin.attack")
      |> Brains.Hoglin.on_hit(target)

    adult = Brains.Hoglin.adult?(self)
    damage = Float32.round(Valimc.Entity.Mob.value(self.type, self.mob, @attack))

    {amount, self} =
      if adult and trunc(damage) > 0 do
        {n, self} = Behavior.level_int(self, trunc(damage))
        {Float32.round(Float32.round(damage / 2.0) + n), self}
      else
        {damage, self}
      end

    {push, self} = if adult, do: throw(self, target), else: {nil, self}
    extras = %{amount: amount, extra_knockback: {0.0, {0.0, 0.0}}, push: push}
    Self.effect(self, {:attack_extra, World.ref(target), extras})
  end

  # `HoglinBase.throwTarget`: its attack knockback less the target's
  # resistance (a tenth for each netherite piece a player wears), away from
  # it and turned a whole number of radians, and up.
  defp throw(self, target) do
    power = Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:attack_knockback")
    power = power - resistance(target)

    if power <= 0.0 do
      {nil, self}
    else
      {xd, zd} = {target.x - self.x, target.z - self.z}
      {n, self} = Behavior.level_int(self, 21)
      {f, self} = Behavior.level_float(self)
      {g, self} = Behavior.level_float(self)
      angle = Float32.round(n - 10)
      horizontal = power * Float32.round(Float32.round(f * 0.5) + Float32.round(0.2))
      length = :math.sqrt(xd * xd + zd * zd)

      {x, z} =
        if length < 1.0e-5,
          do: {0.0, 0.0},
          else: {xd / length * horizontal, zd / length * horizontal}

      cos = Valimc.Data.Mth.cos(angle)
      sin = Valimc.Data.Mth.sin(angle)
      {{x * cos + z * sin, power * g * 0.5, z * cos - x * sin}, self}
    end
  end

  defp resistance(%{kind: :player, equipment: equipment}),
    do: 0.1 * Enum.count([:head, :chest, :legs, :feet], &(equipment[&1] in @netherite))

  defp resistance(_target), do: 0.0
end
