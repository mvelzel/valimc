defmodule Valimc.AI.Mobs.Zombie do
  @moduledoc """
  Zombies, husks and zombie villagers (VMC-043b1), as vanilla's `Zombie`,
  `Husk` and `ZombieVillager`:

  - **Goals** are the zombie's (`Zombie.registerGoals`); a hurt one alerts
    others of its own class (a zombie alerts husks and zombie villagers
    too, never zombified piglins).
  - **Spawning** (`finalizeSpawn`): loot pickup, a baby one time in twenty
    (faster and smaller, a chicken jockey's draws), door breaking, armour
    and a sword, spear or shovel, their enchantments, a Halloween pumpkin,
    then the zombie's own random's reinforcement chance, knockback and
    follow range bonuses and, now and then, a leader. A husk draws its loot
    pickup again and may bring a camel husk ridden by a parched; a zombie
    villager takes its villager type from the biome and its profession from
    its random.
  - **Hits**: a burning bare-handed zombie may set its target alight, a
    bare-handed husk makes it hungry.
  - **Drowning**: a zombie with its eyes in water for 30 s starts turning
    into a drowned 15 s later, a husk into a zombie.
  - Each type's own entity data: the baby flag, the drowned conversion flag
    and a zombie villager's villager data.
  """
  alias Valimc.AI.{Goals, Self, Spawn, World}
  alias Valimc.Data.{Float32, HostileFacts}
  alias Valimc.Entity.Mob
  alias Valimc.Protocol.ItemStack

  @zombie "minecraft:zombie"
  @husk "minecraft:husk"
  @villager "minecraft:zombie_villager"
  @types [@zombie, @husk, @villager]
  # `Zombie.class` and its subclasses but zombified piglins (`setAlertOthers`).
  @alert %{
    @zombie => [@zombie, @husk, "minecraft:drowned", @villager],
    @husk => [@husk],
    @villager => [@villager]
  }
  @villagers ["minecraft:villager", "minecraft:wandering_trader"]
  @turtle_eggs Enum.to_list(Valimc.Data.Blocks.states("turtle_egg"))

  @baby_speed {"minecraft:baby", 0.5, 1}

  def types, do: @types

  ## Goals

  @doc "`Zombie.registerGoals` (husks and zombie villagers keep it)."
  def goals(type) do
    {[
       {4, "ZombieAttackTurtleEggGoal", Goals.RemoveBlock, [:move, :jump],
        Goals.RemoveBlock.new(@turtle_eggs)},
       {8, "LookAtPlayerGoal", Goals.LookAtPlayer, [:look], Goals.LookAtPlayer.new(8.0)},
       {8, "RandomLookAroundGoal", Goals.RandomLookAround, [:move, :look],
        Goals.RandomLookAround.new()},
       {2, "SpearUseGoal", Goals.Idle, [:move, :look], Goals.Idle.new("SpearUseGoal")},
       {3, "ZombieAttackGoal", Goals.MeleeAttack, [:move, :look],
        Goals.MeleeAttack.new(1.0, false, raise_arms: true)},
       {6, "MoveThroughVillageGoal", Goals.Idle, [:move],
        Goals.Idle.new("MoveThroughVillageGoal")},
       {7, "WaterAvoidingRandomStrollGoal", Goals.RandomStroll, [:move],
        Goals.RandomStroll.new(1.0, water_avoiding: true)}
     ],
     [
       {1, "HurtByTargetGoal", Goals.HurtByTarget, [:target],
        Goals.HurtByTarget.new(alert: true, alert_types: @alert[type])},
       {2, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:player, nil, true)},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, @villagers, false)},
       {3, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:iron_golem"], true)},
       # `Turtle.BABY_ON_LAND_SELECTOR`: turtles are VMC-043e's.
       {5, "NearestAttackableTargetGoal", Goals.NearestAttackableTarget, [:target],
        Goals.NearestAttackableTarget.new(:mob, ["minecraft:turtle"], true, interval: 10)}
     ]}
  end

  ## Data

  @doc """
  A type's own data: the baby flag, the special type (unused), whether it
  can break doors, how long its eyes were in water and its drowned
  conversion countdown (-1 when not converting); a zombie villager's
  villager data (`{type, profession, level}`), whether it is final, and
  its cure.
  """
  def data(@villager),
    do:
      Map.merge(data(@zombie), %{
        villager: {"minecraft:plains", "minecraft:none", 1},
        finalized: false,
        cure: -1,
        cure_by: nil,
        xp: 0
      })

  def data(_type),
    do: %{
      baby: false,
      special: 0,
      can_break_doors: false,
      in_water: 0,
      converting: false,
      conversion: -1
    }

  @doc "The entity data values of a body of the family: `[{field, value, default}]`."
  def values(%{type: type, data: data}) do
    [
      {:zombie_baby, data.baby, false},
      {:zombie_special_type, data.special, 0},
      {:zombie_drowned_conversion, data.converting, false}
    ] ++
      if type == @villager,
        do: [
          {:zombie_villager_converting, data.cure >= 0, false},
          # Sent always: vanilla's initial value is a random profession.
          {:zombie_villager_data, data.villager, nil},
          {:zombie_villager_finalized, data.finalized, false}
        ],
        else: []
  end

  @doc "A baby's dimensions (`{width, height, eye}`), or nil for an adult."
  def dimensions(%{type: type, data: %{baby: true}}), do: HostileFacts.baby(type)
  def dimensions(_body), do: nil

  @doc "Whether the body is a baby (`isBaby`)."
  def baby?(%{data: %{baby: baby}}), do: baby

  ## Spawning

  @doc "`finalizeSpawn` of the family's types."
  def finalize(%Self{type: @villager} = self, reason) do
    # The profession its random drew as it was made, then the biome's type.
    self =
      if self.data.finalized do
        self
      else
        {_, _, level} = self.data.villager
        {i, self} = Self.int(self, tuple_size(HostileFacts.professions()))
        profession = elem(HostileFacts.professions(), i)
        biome = World.biome(self.world, Self.block(self))
        villager = {HostileFacts.villager_type(biome), profession, level}
        %{self | data: %{self.data | villager: villager, finalized: true}}
      end

    zombie(self, reason)
  end

  def finalize(%Self{type: @husk} = self, reason) do
    self = zombie(self, reason)
    special = Spawn.special(self)

    self =
      if reason != :conversion do
        {f, self} = Spawn.level_float(self)
        loot(self, f, special)
      else
        self
      end

    camel_husk(self, reason)
  end

  def finalize(self, reason), do: zombie(self, reason)

  defp zombie(self, reason), do: zombie(self, reason, [])

  @doc """
  `Zombie.finalizeSpawn` for a subclass (a zombified piglin, VMC-043d):
  `populate` is its `populateDefaultEquipmentSlots` (on the level's random),
  `reinforcements: false` its `randomizeReinforcementsChance` that draws
  nothing and leaves none.
  """
  def zombie(self, reason, opts) do
    populate = Keyword.get(opts, :populate, &(&1 |> Spawn.armour() |> weapon()))
    self = Spawn.mob(self, reason)
    special = Spawn.special(self)

    self =
      if reason != :conversion do
        {f, self} = Spawn.level_float(self)
        loot(self, f, special)
      else
        self
      end

    # `getSpawnAsBabyOdds`, and a baby's chicken jockey.
    {f, self} = Spawn.level_float(self)
    self = if f < Float32.round(0.05), do: jockey(set_baby(self, true)), else: self

    {f, self} = Spawn.level_float(self)
    self = put_data(self, :can_break_doors, f < Float32.round(special * Float32.round(0.1)))

    self =
      if reason != :conversion do
        self |> populate.() |> Spawn.enchant_equipment()
      else
        self
      end

    self = halloween(self)
    handle_attributes(self, special, reason, Keyword.get(opts, :reinforcements, true))
  end

  defp loot(self, f, special),
    do: %{
      self
      | mob: %{self.mob | can_pick_up_loot: f < Float32.round(Float32.round(0.55) * special)}
    }

  defp put_data(self, key, value), do: %{self | data: Map.put(self.data, key, value)}

  @doc "`setBaby`: the flag and the baby speed modifier."
  def set_baby(self, baby) do
    self = put_data(self, :baby, baby)
    entry = Map.get(self.mob.attributes, "minecraft:movement_speed", %{base: nil, modifiers: []})
    modifiers = Enum.reject(entry.modifiers, &(elem(&1, 0) == "minecraft:baby"))
    modifiers = if baby, do: modifiers ++ [@baby_speed], else: modifiers
    entry = %{entry | modifiers: modifiers}

    attributes =
      if entry == %{base: nil, modifiers: []},
        do: Map.delete(self.mob.attributes, "minecraft:movement_speed"),
        else: Map.put(self.mob.attributes, "minecraft:movement_speed", entry)

    %{self | mob: %{self.mob | attributes: attributes}}
  end

  # A baby rides a nearby chicken one time in twenty, else one time in
  # twenty a new one (riding is VMC-046's: the chicken stays beside it).
  defp jockey(self) do
    {f, self} = Spawn.level_float(self)

    if f < 0.05 do
      box = World.inflate(Self.box(self), 5.0, 3.0, 5.0)

      case World.mobs_in(self, ["minecraft:chicken"], box) do
        [chicken | _] -> Self.effect(self, {:jockey, chicken.uuid})
        [] -> self
      end
    else
      {f, self} = Spawn.level_float(self)
      if f < 0.05, do: new_chicken(self), else: self
    end
  end

  # `EntityTypes.CHICKEN.create(JOCKEY)` at the zombie, finalized at once:
  # its variant (one candidate of its climate) and sound variant, then
  # `Mob`'s draws (its variant itself is VMC-043c's).
  defp new_chicken(self) do
    {_, self} = Spawn.level_int(self, 1)
    sounds = length(Valimc.Protocol.Data.registries()["minecraft:chicken_sound_variant"])
    {_, self} = Spawn.level_int(self, sounds)
    {a, self} = Spawn.level_double(self)
    {b, self} = Spawn.level_double(self)
    {f, self} = Spawn.level_float(self)

    Self.effect(
      self,
      {:spawn, "minecraft:chicken",
       %{
         jockey: true,
         yaw: self.yaw,
         left_handed: f < Float32.round(0.05),
         follow_bonus: 0.11485000000000001 * (a - b)
       }}
    )
  end

  # `Zombie.populateDefaultEquipmentSlots`: after the armour, a sword, spear
  # or shovel a hundredth of the time (a twentieth on hard).
  defp weapon(self) do
    {f, self} = Spawn.level_float(self)

    if f < Float32.round(if self.world.difficulty == :hard, do: 0.05, else: 0.01) do
      {n, self} = Spawn.level_int(self, 6)

      item =
        case n do
          0 -> "iron_sword"
          1 -> "iron_spear"
          _ -> "iron_shovel"
        end

      Spawn.equip(self, :mainhand, ItemStack.new(item))
    else
      self
    end
  end

  # At Halloween a quarter of those with a bare head wear a carved pumpkin
  # (a jack o'lantern one time in ten) that never drops.
  defp halloween(self) do
    if self.mob.equipment[:head] == nil and self.world.halloween do
      {f, self} = Spawn.level_float(self)

      if f < Float32.round(0.25) do
        {g, self} = Spawn.level_float(self)
        item = if g < Float32.round(0.1), do: "jack_o_lantern", else: "carved_pumpkin"
        self = Spawn.equip(self, :head, ItemStack.new(item))
        %{self | mob: Mob.put_drop_chance(self.mob, :head, 0.0)}
      else
        self
      end
    else
      self
    end
  end

  @doc """
  `Zombie.handleAttributes`, from the zombie's own random: its reinforcement
  chance, a knockback resistance and follow range bonus and, by chance, a
  leader (more reinforcements and health, door breaking).
  """
  def handle_attributes(self, special, reason, reinforcements \\ true) do
    self =
      if reinforcements do
        {d, self} = Self.double(self)
        Spawn.set_base(self, "minecraft:spawn_reinforcements", d * Float32.round(0.1))
      else
        Spawn.set_base(self, "minecraft:spawn_reinforcements", 0.0)
      end

    {d, self} = Self.double(self)

    self =
      Spawn.add_modifier(
        self,
        "minecraft:knockback_resistance",
        {"minecraft:random_spawn_bonus", d * Float32.round(0.05), 0}
      )

    {d, self} = Self.double(self)
    follow = d * 1.5 * special

    self =
      if follow > 1.0,
        do:
          Spawn.add_modifier(
            self,
            "minecraft:follow_range",
            {"minecraft:zombie_random_spawn_bonus", follow, 2}
          ),
        else: self

    {f, self} = Self.float(self)

    if f < Float32.round(special * Float32.round(0.05)) do
      {d, self} = Self.double(self)

      self =
        Spawn.add_modifier(
          self,
          "minecraft:spawn_reinforcements",
          {"minecraft:leader_zombie_bonus", d * 0.25 + 0.5, 0}
        )

      {d, self} = Self.double(self)

      self =
        Spawn.add_modifier(
          self,
          "minecraft:max_health",
          {"minecraft:leader_zombie_bonus", d * 3.0 + 1.0, 2}
        )

      self =
        if reason in [:conversion, :load, :dimension_travel],
          do: self,
          else: full_health(self)

      put_data(self, :can_break_doors, true)
    else
      self
    end
  end

  defp full_health(%Self{mob: mob, type: type} = self) do
    max = Float32.round(Mob.value(type, mob, "minecraft:max_health"))
    health = %{mob.living.health | value: max}
    %{self | mob: %{mob | living: %{mob.living | health: health}}}
  end

  # A husk's natural spawn where a camel husk fits: one time in ten an iron
  # spear and a camel husk ridden by a parched (riding is VMC-046's).
  defp camel_husk(self, :natural) do
    {x, y, z} = Self.block(self)
    %{width: w, height: h} = Valimc.Data.EntityTypes.fetch("minecraft:camel_husk")
    half = Float32.round(w) / 2.0

    box =
      {x + 0.5 - half, y * 1.0, z + 0.5 - half, x + 0.5 + half, y + Float32.round(h),
       z + 0.5 + half}

    if World.fits?(self.world, box) do
      {f, self} = Spawn.level_float(self)

      if f < Float32.round(0.1) do
        self
        |> Spawn.equip(:mainhand, ItemStack.new("iron_spear"))
        |> Self.effect({:spawn, "minecraft:camel_husk", %{reason: :natural}})
        |> Self.effect({:spawn, "minecraft:parched", %{reason: :natural}})
      else
        self
      end
    else
      self
    end
  end

  defp camel_husk(self, _reason), do: self
end
