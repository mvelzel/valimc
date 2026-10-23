defmodule Valimc.AI.Mobs.IronGolem do
  @moduledoc """
  `IronGolem` (VMC-044a2): it guards villages. Its goals walk it at
  monsters (not creepers) near it and at a player it is angry with, back to
  the village when outside it and about the village toward villagers that
  want a golem or its claimed POIs, and now and then by day it offers a
  villager a flower. Its hit (`doHurtTarget`) is 7.5 to 21.5 and throws its
  target up; it shows its attack (entity event 4) and plays its sound. It
  stays angry with a player who hurt it (`Valimc.AI.Neutral`, 20 to 39
  seconds), never targets players when a player built it, and pushing a
  monster makes it its target one time in twenty.

  Its own data: whether a player built it (`PlayerCreated`, entity data
  bit 0). Its own mind fields (`Mind.own`): the neutral fields and its
  attack and flower animation timers.
  """
  @behaviour Valimc.AI.Kind
  alias Valimc.AI
  alias Valimc.AI.{Goals, Neutral, Pois, RandomPos, Self, Villagers, World}
  alias Valimc.Data.{EntityTypes, Float32}

  @type_name "minecraft:iron_golem"
  @anger {400, 780}
  @tiny Valimc.Data.Float32.round(2.5000003e-7)

  @impl true
  def types, do: [@type_name]

  # `Mob.canBeLeashed`: a golem is no `Enemy`.
  @impl true
  def leashable?, do: true

  @impl true
  def goals(_type) do
    nat = Goals.NearestAttackableTarget

    {[
       {1, "MeleeAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, true)},
       {2, "MoveTowardsTargetGoal", Goals.MoveTowardsTarget, [:move],
        Goals.MoveTowardsTarget.new(0.9, 32.0)},
       {2, "MoveBackToVillageGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(0.6,
          interval: 10,
          check_idle: false,
          guard: &(not Pois.village?(&1.world, Self.block(&1))),
          position: &back_to_village/1
        )},
       {4, "GolemRandomStrollInVillageGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(0.6, interval: 240, check_idle: false, position: &in_village/1)},
       {5, "OfferFlowerGoal", __MODULE__.OfferFlower, [:move, :look], %{entity: nil, tick: 0}},
       {7, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(6.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()}
     ],
     [
       # Reputation is VMC-044's: no villager knows a player it would turn on.
       {1, "DefendVillageTargetGoal", Goals.Idle, [:target],
        Goals.Idle.new("DefendVillageTargetGoal")},
       {2, "HurtByTargetGoal", Goals.HurtByTarget, [:target], Goals.HurtByTarget.new()},
       {3, "NearestAttackableTargetGoal", nat, [:target],
        nat.new(:player, nil, true, interval: 10, selector: &Neutral.angry_at?(&2, &1))},
       {3, "NearestAttackableTargetGoal", nat, [:target],
        nat.new(:mob, &enemy?/1, false, interval: 5)},
       {4, "ResetUniversalAngerTargetGoal", Goals.ResetUniversalAnger, [],
        Goals.ResetUniversalAnger.new(@anger)}
     ]}
  end

  # `target instanceof Enemy && !(target instanceof Creeper)`.
  defp enemy?(type), do: type != "minecraft:creeper" and EntityTypes.fetch(type).enemy == true

  @impl true
  def data(_type), do: %{player_created: false}

  @impl true
  def values(%{data: data}),
    do: [{:iron_golem_flags, if(data.player_created, do: 1, else: 0), 0}]

  @impl true
  def can_attack?(%Self{data: data}, target) do
    cond do
      data.player_created and target.kind == :player -> false
      Map.get(target, :type) == "minecraft:creeper" -> false
      true -> true
    end
  end

  ## Its own mind fields

  defp own, do: Map.merge(Neutral.fields(), %{attack: 0, flower: 0})

  defp ensure(%Self{mind: %{own: nil}} = self), do: Self.mind(self, &%{&1 | own: own()})
  defp ensure(self), do: self

  defp put(self, changes), do: Self.mind(ensure(self), &%{&1 | own: Map.merge(&1.own, changes)})

  ## Its fights

  @doc """
  `doHurtTarget`: the attack shown (event 4, its timer at 10), a hit of half
  its attack damage and up to 14 more (drawn from its random) in place of a
  mob's, that throws the target up (0.4, less its knockback resistance)
  without the extra knockback, and its attack sound.
  """
  @impl true
  def hit(%Self{} = self, target) do
    self = self |> put(%{attack: 10}) |> Self.effect({:event, 4})

    damage =
      Float32.round(Valimc.Entity.Mob.value(self.type, self.mob, "minecraft:attack_damage"))

    {amount, self} =
      if trunc(damage) > 0 do
        {n, self} = Self.int(self, trunc(damage))
        {Float32.round(Float32.round(damage / 2.0) + n), self}
      else
        {damage, self}
      end

    self
    |> Self.effect(
      {:attack_extra, World.ref(target),
       %{amount: amount, lift: Float32.round(0.4), extra_knockback: nil}}
    )
    |> Self.effect(
      {:sound, Villagers.sound_id("minecraft:entity.iron_golem.attack"), source(), 1.0, 1.0,
       seed()}
    )
  end

  defp source, do: Valimc.Protocol.CombatPackets.mob_sounds(@type_name)["sound_source"]

  defp seed do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
    seed
  end

  @doc """
  `IronGolem.hurtServer`: a hurt that changes its crackiness (`Crackiness.GOLEM`:
  below three quarters, half and a quarter of its health) plays its damage
  sound.
  """
  @impl true
  def hurt_events(%{type: type, mob: mob}, before) do
    max = Valimc.Entity.Mob.value(type, mob, "minecraft:max_health")
    now = mob.living.health.value

    if crackiness(Float32.round(now / max)) != crackiness(Float32.round(before / max)),
      do: [
        {:sound, Villagers.sound_id("minecraft:entity.iron_golem.damage"), source(), 1.0, 1.0,
         seed()}
      ],
      else: []
  end

  defp crackiness(f) do
    cond do
      f < 0.25 -> :high
      f < 0.5 -> :medium
      f < 0.75 -> :low
      true -> :none
    end
  end

  @doc """
  `Entity.baseTick`'s `canSpawnSprintParticle`, which a golem overrides: a
  golem moving (more than a tiny speed) draws on its random each tick.
  """
  @impl true
  def tick_start(%Self{velocity: {vx, _, vz}} = self) do
    if vx * vx + vz * vz > @tiny do
      {n, self} = Self.int(self, 5)
      if n == 0, do: Self.sprint_particle(self), else: self
    else
      self
    end
  end

  @doc """
  `IronGolem.aiStep` after the move: the monsters it pushes (one in twenty
  becomes its target, `doPush`), its timers run down, its anger kept up
  (`updatePersistentAnger`, staying angry while it has a target).
  """
  @impl true
  def after_ai(%Self{} = self) do
    self = ensure(self) |> pushes()
    own = self.mind.own
    self = put(self, %{attack: max(own.attack - 1, 0), flower: max(own.flower - 1, 0)})
    Neutral.update(self, true, @anger)
  end

  # `pushEntities`'s `doPush`: each pushable mob its box meets.
  defp pushes(%Self{world: world} = self) do
    box = Self.box(self)

    Enum.reduce(world.mobs, self, fn m, self ->
      if m.uuid != self.uuid and m.alive and enemy?(m.type) and
           World.intersects?(World.box(m), box) do
        {n, self} = Self.int(self, 20)
        if n == 0, do: Self.set_target(self, World.ref(m)), else: self
      else
        self
      end
    end)
  end

  ## Walks

  # `MoveBackToVillageGoal.getPosition`: toward the nearest section closer to
  # a village, or nowhere.
  defp back_to_village(self) do
    section = Pois.section(Self.block(self))

    case Pois.closest_village_section(self.world, section, 2) do
      ^section ->
        {nil, self}

      {sx, sy, sz} ->
        RandomPos.default_towards(
          self,
          10,
          7,
          {sx * 16 + 8.5, sy * 16 + 8.0, sz * 16 + 8.5},
          Float32.round(:math.pi() / 2)
        )
    end
  end

  # `GolemRandomStrollInVillageGoal.getPosition`, its draws from the level's random.
  defp in_village(self) do
    {f, self} = AI.Behavior.level_float(self)

    if f < Float32.round(0.3) do
      RandomPos.land(self, 10, 7)
    else
      {g, self} = AI.Behavior.level_float(self)

      {target, self} =
        if g < Float32.round(0.7) do
          case toward_villager(self) do
            {nil, self} -> toward_poi(self)
            found -> found
          end
        else
          case toward_poi(self) do
            {nil, self} -> toward_villager(self)
            found -> found
          end
        end

      if target == nil, do: RandomPos.land(self, 10, 7), else: {target, self}
    end
  end

  defp toward_villager(self) do
    box = World.inflate(Self.box(self), 32.0, 32.0, 32.0)
    now = self.world.time

    villagers =
      for m <- World.mobs_in(self, ["minecraft:villager"], box),
          Valimc.AI.Brains.Villager.wants_golem?(m, now),
          do: m

    case villagers do
      [] ->
        {nil, self}

      _ ->
        {i, self} = AI.Behavior.level_int(self, length(villagers))
        v = Enum.at(villagers, i)
        RandomPos.land_towards(self, 10, 7, {v.x, v.y, v.z})
    end
  end

  defp toward_poi(self) do
    sections =
      for s <- Pois.cube(Pois.section(Self.block(self)), 2),
          Pois.sections_to_village(self.world, s) == 0,
          do: s

    case sections do
      [] ->
        {nil, self}

      _ ->
        {i, self} = AI.Behavior.level_int(self, length(sections))
        {sx, sy, sz} = Enum.at(sections, i)
        center = {sx * 16 + 8, sy * 16 + 8, sz * 16 + 8}

        pois =
          for {_, pos} <- Pois.in_range(self.world, Pois.types(), center, 8, :occupied), do: pos

        case pois do
          [] ->
            {nil, self}

          _ ->
            {j, self} = AI.Behavior.level_int(self, length(pois))
            {x, y, z} = Enum.at(pois, j)
            RandomPos.land_towards(self, 10, 7, {x + 0.5, y * 1.0, z + 0.5})
        end
    end
  end

  ## Offering a flower

  defmodule OfferFlower do
    @moduledoc false
    use Valimc.AI.Goal

    @gift "candidate_for_iron_golem_gift"

    # `OfferFlowerGoal`: by day, one tick in 8000, a villager within 6 blocks.
    def can_use(state, self) do
      if not self.world.bright do
        {false, state, self}
      else
        {n, self} = Self.int(self, 8000)

        if n != 0 do
          {false, state, self}
        else
          box = World.inflate(Self.box(self), 6.0, 2.0, 6.0)
          conditions = World.conditions(false, range: 6.0)
          select = &Valimc.Data.EntityTypes.tag?(&1, @gift)

          {entity, self} =
            World.nearest_mob(self, select, box, conditions, self.x, self.y, self.z)

          {entity != nil, %{state | entity: World.ref(entity)}, self}
        end
      end
    end

    def can_continue(state, self), do: {state.tick > 0, state, self}

    def start(state, self) do
      self =
        Self.mind(self, &%{&1 | own: Map.put(&1.own || %{}, :flower, 400)})
        |> Self.effect({:event, 11})

      {%{state | tick: adjusted(state, 400)}, self}
    end

    def stop(state, self) do
      self =
        Self.mind(self, &%{&1 | own: Map.put(&1.own || %{}, :flower, 0)})
        |> Self.effect({:event, 34})

      {%{state | entity: nil}, self}
    end

    def tick(state, self) do
      self =
        case World.entity(self.world, state.entity) do
          nil -> self
          e -> Self.look_at(self, {e.x, World.eye_y(e), e.z}, 30.0, 30.0)
        end

      {%{state | tick: state.tick - 1}, self}
    end
  end
end
