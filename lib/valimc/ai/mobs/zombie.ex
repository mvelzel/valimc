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
  # Drowned keep a zombie's data; their own goals are VMC-043b2's.
  @drowned "minecraft:drowned"
  @types [@zombie, @husk, @villager, @drowned]
  # `Zombie.class` and its subclasses but zombified piglins (`setAlertOthers`).
  @alert %{
    @zombie => [@zombie, @husk, "minecraft:drowned", @villager],
    @husk => [@husk],
    @villager => [@villager],
    @drowned => [@drowned]
  }
  @villagers ["minecraft:villager", "minecraft:wandering_trader"]
  @turtle_eggs Enum.to_list(Valimc.Data.Blocks.states("turtle_egg"))

  @baby_speed {"minecraft:baby", 0.5, 1}
  @hunger Valimc.Data.EffectTypes.id("hunger")

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

  @doc "A baby's higher voice (`getVoicePitch`; a baby zombie villager's higher still)."
  def voice(@villager, %{baby: true}), do: 2.0
  def voice(_type, %{baby: true}), do: 1.5
  def voice(_type, _data), do: 1.0

  @doc "Whether the body is a baby (`isBaby`)."
  def baby?(%{data: %{baby: baby}}), do: baby

  ## Drowning

  # `convertsInWater` and `convertsToWhenDrowning` with the conversion's
  # level event (`getConversionSound`).
  @converts %{@zombie => {"minecraft:drowned", 1040}, @husk => {@zombie, 1041}}

  @doc """
  `Zombie.tick`'s drowning tracker (`ConversionTracker`), after the move:
  with its eyes in water for 600 ticks a zombie starts converting, 300 ticks
  later it becomes a drowned (a husk a zombie): a `{:convert, type}` effect
  and the conversion's level event. Out of water it starts over.
  """
  def after_move(%{type: type, mob: mob, data: data} = body, {x, y, z}, ticked)
      when is_map_key(@converts, type) do
    if Mob.alive?(mob) and not mob.no_ai do
      if Valimc.Living.Air.submerged?(ticked.eye_water, ticked.eye_state) do
        if data.converting do
          conversion = data.conversion - 1

          if conversion < 0 do
            {to, event} = @converts[type]
            cell = {floor(x), floor(y), floor(z)}

            {%{body | data: %{data | conversion: conversion}},
             [{:convert, to}, {:level_event, cell, event, 0}]}
          else
            {%{body | data: %{data | conversion: conversion}}, []}
          end
        else
          in_water = data.in_water + 1

          data =
            if in_water >= 600,
              do: %{data | in_water: in_water, converting: true, conversion: 300},
              else: %{data | in_water: in_water}

          {%{body | data: data}, []}
        end
      else
        {%{body | data: %{data | in_water: -1, converting: false}}, []}
      end
    else
      {body, []}
    end
  end

  def after_move(body, _position, _ticked), do: {body, []}

  @doc """
  The mob a converting `body` becomes (`Mob.convertTo` with
  `ConversionParams.single(keepEquipment, preserveCanPickUpLoot)`): a fresh
  `to` with `uuid` that keeps its rotation, motion, equipment and drop
  chances, effects, absorption, hurt time, the player that hurt it, baby
  flag, loot pickup, handedness, persistence and name; then the zombie's
  attributes drawn from its own random at the `special` multiplier
  (`handleAttributes` for a conversion).
  """
  def convert(%Valimc.Entity.Body{} = body, uuid, to, special) do
    {:ok, new} = Valimc.Entity.Body.new(to)
    mob = body.mob
    living = mob.living

    fresh = %{
      new.mob
      | equipment: mob.equipment,
        drop_chances: mob.drop_chances,
        motion: %{new.mob.motion | fall_distance: mob.motion.fall_distance},
        player_memory: mob.player_memory,
        hurt_by_player: mob.hurt_by_player,
        living: %{
          new.mob.living
          | effects: living.effects,
            absorption: living.absorption,
            health: %{new.mob.living.health | hurt_ticks: living.health.hurt_ticks}
        },
        can_pick_up_loot: mob.can_pick_up_loot,
        left_handed: mob.left_handed,
        no_ai: mob.no_ai,
        persistent: mob.persistent
    }

    new = %{
      new
      | yaw: body.yaw,
        pitch: body.pitch,
        head_yaw: body.head_yaw,
        velocity: body.velocity,
        on_ground: body.on_ground,
        no_gravity: body.no_gravity,
        custom_name: body.custom_name,
        portal_cooldown: body.portal_cooldown,
        mob: fresh
    }

    mind = Valimc.AI.mind(to, uuid, nil)
    self = %Self{type: to, uuid: uuid, mob: new.mob, mind: mind, data: new.data}
    self = if baby?(body), do: set_baby(self, true), else: self
    self = handle_attributes(self, special, :conversion)
    %{new | data: self.data, mob: %{self.mob | ai: self.mind}}
  end

  ## Loot

  @glow_ink Valimc.Protocol.ItemTypes.id("glow_ink_sac")

  @doc "`Zombie.wantsToPickUp`: anything it can hold but glow ink sacs."
  def wants?(_self, item), do: item != @glow_ink

  ## Hits

  @doc """
  `Zombie.doHurtTarget` after the hit: a burning bare-handed zombie sets the
  target alight for twice the local difficulty's seconds by a chance that
  grows with it; a bare-handed husk then makes it hungry (`Husk`). The hit
  is taken as landed.
  """
  def hit(%Self{mob: mob} = self, target) do
    difficulty = Valimc.Living.LocalDifficulty.effective(Spawn.local(self))
    bare = mob.equipment[:mainhand] == nil

    {extras, self} =
      if bare and mob.living.fire_ticks > 0 do
        {f, self} = Self.float(self)

        if f < Float32.round(difficulty * Float32.round(0.3)),
          do: {%{ignite: 2 * trunc(difficulty) * 20}, self},
          else: {%{}, self}
      else
        {%{}, self}
      end

    extras =
      if self.type == @husk and bare,
        do: Map.put(extras, :effect, {@hunger, {140 * trunc(difficulty), 0, false, true, true}}),
        else: extras

    if extras == %{},
      do: self,
      else: Self.effect(self, {:attack_extra, World.ref(target), extras})
  end

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
