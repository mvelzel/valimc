defmodule Valimc.AI do
  @moduledoc """
  Mob AI (VMC-041a), run by the owning group once per section per tick,
  never as a process per mob. Before the physics kernel moves a section's
  mobs, `think/2` runs each living mob's part of vanilla's tick in id order:
  `checkDespawn`'s idle reset near a player, `tickCount`, the expiry of who
  hurt it, `Mob.baseTick`'s ambient sound, a monster's idle time in light,
  and `Mob.serverAiStep`: its target and goal selectors (`Valimc.AI.Selector`:
  a full update on alternate ticks by its id, otherwise only goals updated
  every tick), its navigation and its look control. The kernel then runs the
  move and jump controls with what the AI set; `settle/2` runs the body
  rotation control and an animal's age after the move.

  Each mob's random is its own and deterministic (`Valimc.AI.Random`,
  seeded from its uuid and saved), so a mob draws what vanilla's would.
  What the AI decides that leaves the mob comes back as effects: a melee hit
  (`{:attack, target}`, `Mob.doHurtTarget` through VMC-037n), a swing, an
  alert of another mob, a breeding. A mob's AI reads only its own state and
  `Valimc.AI.World`: the section's mobs, the group's players and published
  block snapshots; its cost per tick is bounded by its goals' searches,
  which read a bounded box.
  """
  alias Valimc.AI.{Facts, Look, Mind, Mobs, Navigation, Random, Selector, Self, World}
  alias Valimc.Data.EntityTypes
  alias Valimc.Entity.{Body, Mob}

  @doc "Whether mobs of `type` have an AI."
  def thinks?(type), do: Facts.mob(type) != nil and Mobs.goals?(type)

  # A `NoAI` mob runs none of it (`Mob.isEffectiveAi`).
  defp thinking?(%Body{type: type, mob: mob}), do: thinks?(type) and not mob.no_ai

  @doc """
  A mob's mind from what its record kept (`ai`: nil for a new mob, else
  `Mind.record/1`'s map), its random seeded from `uuid` when new.
  """
  def mind(type, uuid, kept) do
    random =
      case kept do
        %Mind{random: random} -> random
        %{random: random} -> random
        nil -> Random.new(uuid)
      end

    {goals, targets, floats} = Mobs.selectors(type)
    {kind, options} = Mobs.navigation(type)
    navigation = Navigation.new(kind, options)

    navigation =
      if floats and kind in [:ground, :fly], do: %{navigation | can_float: true}, else: navigation

    mind = %Mind{
      random: random,
      goals: goals,
      targets: targets,
      navigation: navigation
    }

    case Mobs.brain(type) do
      nil ->
        mind

      module ->
        {brain, random} = module.brain(mind.random, module.gates(uuid))
        %{mind | brain: brain, random: random}
    end
  end

  @doc """
  What others read of a mob of a section (`Valimc.AI.World`'s sensed mob):
  `{id, entry}` of the store.
  """
  def sensed({id, %{entity: e, body: %Body{type: type, mob: mob} = body}}) do
    {width, height, eye} = Body.dimensions(body)
    mind = match_mind(mob.ai)
    position = {e.x * 1.0, e.y * 1.0, e.z * 1.0}

    %{
      kind: :mob,
      uuid: e.uuid,
      id: id,
      type: type,
      x: e.x * 1.0,
      y: e.y * 1.0,
      z: e.z * 1.0,
      yaw: body.yaw,
      pitch: body.pitch,
      eye: eye,
      width: width,
      height: height,
      # A family's own bounding box (a shulker's lid), else the usual one.
      box: Mobs.hook(type, :box, [body, position], nil),
      alive: Mob.alive?(mob),
      target: mind && mind.target,
      in_love: (mind && mind.in_love) || 0,
      age: (mind && mind.age) || 0,
      panicking:
        mind != nil and
          Valimc.AI.Goals.Panic in Selector.running(%Self{mind: mind}, :goals)
    }
  end

  defp match_mind(%Mind{} = mind), do: mind
  defp match_mind(_), do: nil

  @doc """
  The AI part of one tick of the section's mobs (`[{id, entry}]` in id
  order) over `world`: `{[{id, body, position, effects}], world}` with each
  mob's new body (rotations, travel control, mind), where it is before the
  move (a family may teleport it) and the effects it made, oldest first, and the world as they left it (its level random drawn on). Mobs
  whose type has no AI, and dying mobs, keep their body and make none. An
  alert sets the other mob's target at once, as vanilla does: a mob later
  in order thinks with it, one earlier keeps it for its next tick.
  """
  def think(mobs, %World{} = world) do
    mobs = Enum.map(mobs, fn {id, entry} -> {id, ensure(entry)} end)
    sensed = Enum.map(mobs, &sensed/1)
    world = %{world | mobs: sensed, by_type: Enum.group_by(sensed, & &1.type)}
    order = mobs |> Enum.with_index() |> Map.new(fn {{_, e}, i} -> {e.entity.uuid, i} end)

    {results, {late, world}} =
      mobs
      |> Enum.with_index()
      |> Enum.map_reduce({%{}, world}, fn {{id, entry}, index}, {alerts, world} ->
        entry = alert(entry, alerts[entry.entity.uuid], world)
        {body, position, effects, world} = think_one(id, entry, world)

        alerts =
          for {:alert, uuid, target} <- effects, reduce: alerts do
            acc ->
              if order[uuid] > index,
                do: Map.put(acc, uuid, target),
                else: Map.put(acc, {:late, uuid}, target)
          end

        {{id, body, position, effects}, {alerts, world}}
      end)

    results =
      for {{id, body, position, effects}, {_, entry}} <- Enum.zip(results, mobs) do
        case late[{:late, entry.entity.uuid}] do
          nil ->
            {id, body, position, effects}

          target ->
            {id, alerted(body, entry.entity.uuid, target, world), position, effects}
        end
      end

    {results, world}
  end

  # A mob of a type with an AI thinks with a mind (from its record, or new).
  defp ensure(%{entity: e, body: %Body{type: type, mob: %Mob{ai: ai} = mob} = body} = entry) do
    if thinks?(type) and not match?(%Mind{}, ai),
      do: %{entry | body: %{body | mob: %{mob | ai: mind(type, e.uuid, ai)}}},
      else: entry
  end

  defp alert(entry, nil, _world), do: entry

  defp alert(%{body: %{mob: %{ai: %Mind{}}} = body} = entry, target, world),
    do: %{entry | body: alerted(body, entry.entity.uuid, target, world)}

  defp alert(entry, _target, _world), do: entry

  # Another mob's alert sets the target through the type's `setTarget`.
  defp alerted(%Body{type: type, mob: %Mob{ai: %Mind{} = mind} = mob} = body, uuid, target, world) do
    self =
      Self.set_target(%Self{type: type, uuid: uuid, mob: mob, mind: mind, world: world}, target)

    %{body | mob: %{mob | ai: self.mind}}
  end

  defp think_one(id, %{entity: e, body: %Body{} = body}, world) do
    # A mob still to finalize its spawn does so first (VMC-043b), with or
    # without goals.
    {body, made, world} = finalize(id, e, body, world)
    %Body{type: type, mob: mob} = body

    if not thinking?(%Body{type: type, mob: mob}) or not Mob.alive?(mob) do
      {body, {e.x, e.y, e.z}, made, world}
    else
      {width, height, eye} = Body.dimensions(body)

      self = %Self{
        id: id,
        uuid: e.uuid,
        type: type,
        x: e.x * 1.0,
        y: e.y * 1.0,
        z: e.z * 1.0,
        yaw: body.yaw,
        pitch: body.pitch,
        head: body.head_yaw,
        on_ground: body.on_ground,
        velocity: body.velocity,
        mob: mob,
        mind: mob.ai,
        facts: Facts.mob(type),
        width: width,
        height: height,
        eye: eye,
        data: body.data,
        world: world
      }

      # A family's `tick` before its super, and its `aiStep` before its
      # super (`Valimc.AI.Kind`).
      self =
        self
        |> despawn_check()
        |> hook(:tick_start)
        |> base_tick()
        |> hook(:before_ai)
        |> ai_step()

      motion = %{self.mob.motion | jump: self.mind.jump, rise: self.mind.rise}
      mob = %{self.mob | ai: self.mind, motion: motion}
      mob = %{mob | ai: %{mob.ai | jump: false, rise: false}}

      {%{
         body
         | yaw: self.yaw,
           pitch: self.pitch,
           head_yaw: self.head,
           velocity: self.velocity,
           mob: mob,
           data: self.data
       }, {self.x, self.y, self.z}, made ++ Enum.reverse(self.effects),
       %{world | random: self.world.random, loot_seeds: self.world.loot_seeds}}
    end
  end

  # `finalizeSpawn` of a mob that has not run it (`Valimc.AI.Spawn`): with its
  # mind's random where it thinks, else one seeded from its uuid.
  defp finalize(_id, _e, %Body{mob: %Mob{finalize: nil}} = body, world), do: {body, [], world}

  defp finalize(id, e, %Body{type: type, mob: mob} = body, world) do
    {width, height, eye} = Body.dimensions(body)
    mind = if match?(%Mind{}, mob.ai), do: mob.ai, else: %Mind{random: Random.new(e.uuid)}

    self =
      Valimc.AI.Spawn.finalize(%Self{
        id: id,
        uuid: e.uuid,
        type: type,
        x: e.x * 1.0,
        y: e.y * 1.0,
        z: e.z * 1.0,
        yaw: body.yaw,
        pitch: body.pitch,
        head: body.head_yaw,
        on_ground: body.on_ground,
        mob: mob,
        mind: mind,
        facts: Facts.mob(type),
        width: width,
        height: height,
        eye: eye,
        data: body.data,
        world: world
      })

    mob = if match?(%Mind{}, mob.ai), do: %{self.mob | ai: self.mind}, else: self.mob

    {%{body | mob: mob, data: self.data}, Enum.reverse(self.effects),
     %{world | random: self.world.random}}
  end

  # `Mob.checkDespawn` without despawning (VMC-042a): near a player the mob
  # is not idle; an idle mob far from every player draws its chance to go.
  defp despawn_check(%Self{world: world} = self) do
    nearest =
      world.players
      |> Enum.reject(&(&1.mode == :spectator))
      |> Enum.map(&Self.distance_sq(self, {&1.x, &1.y, &1.z}))
      |> Enum.min(fn -> nil end)

    distance = category(self.type)["no_despawn_distance"]

    cond do
      nearest == nil ->
        self

      self.mind.no_action > 600 ->
        {n, self} = Self.int(self, 800)

        if n == 0 and nearest > distance * distance,
          do: self,
          else:
            if(nearest < distance * distance,
              do: Self.mind(self, &%{&1 | no_action: 0}),
              else: self
            )

      nearest < distance * distance ->
        Self.mind(self, &%{&1 | no_action: 0})

      true ->
        self
    end
  end

  defp category(type), do: EntityTypes.category(EntityTypes.fetch(type).category)

  # `tickCount++`, `LivingEntity.baseTick`'s expiry of who hurt it (dead,
  # gone, or 100 ticks ago) and `Mob.baseTick`'s ambient sound.
  defp base_tick(%Self{} = self) do
    self = Self.mind(self, &%{&1 | tick: &1.tick + 1})

    self =
      case self.mind.hurt_by do
        {ref, at} ->
          case World.entity(self.world, ref) do
            %{alive: true} when self.mind.tick - at <= 100 -> self
            _ -> Self.mind(self, &%{&1 | hurt_by: nil})
          end

        nil ->
          self
      end

    {n, self} = Self.int(self, 1000)
    ambient = self.mind.ambient
    self = Self.mind(self, &%{&1 | ambient: ambient + 1})

    if n < ambient do
      self = Self.mind(self, &%{&1 | ambient: -self.facts.ambient_interval})
      ambient_sound(self)
    else
      self
    end
  end

  # `Mob.playAmbientSound`: a brain mob's depends on what it is doing.
  defp ambient_sound(%Self{mind: %{brain: %Valimc.AI.Brain{module: module}}} = self),
    do: make_sound(self, module.ambient_sound(self))

  defp ambient_sound(%Self{facts: facts} = self),
    do: make_sound(self, Mobs.hook(self.type, :ambient_sound, [self], facts.ambient_sound))

  @doc """
  `LivingEntity.makeSound`: sound `name` (nil plays none) at the mob's
  volume and voice pitch, drawn from its random.
  """
  def make_sound(self, nil), do: self

  def make_sound(%Self{facts: facts} = self, name) do
    {pitch, random} = Random.voice_pitch(self.mind.random, Mobs.voice(self.type, self.data))
    self = Self.mind(self, &%{&1 | random: random})
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    Self.effect(
      self,
      {:sound, Facts.sound_id(name), source(self.type), facts.volume, pitch, seed}
    )
  end

  defp source(type), do: Valimc.Protocol.CombatPackets.mob_sounds(type)["sound_source"]

  # `LivingEntity.aiStep` up to the move: a monster's idle time in light,
  # then `serverAiStep`.
  defp ai_step(%Self{} = self) do
    self =
      if EntityTypes.fetch(self.type).category == :monster and light(self) > 0.5,
        do: Self.mind(self, &%{&1 | no_action: &1.no_action + 2}),
        else: self

    self = Self.mind(self, &%{&1 | no_action: &1.no_action + 1, sight: %{}})
    # A deferred search's result arrives before the goals look (VMC-041b).
    self = Navigation.receive(self)
    tick = self.mind.tick

    self =
      if rem(tick + self.id, 2) != 0 and tick > 1 do
        self |> Selector.tick_running(:targets, false) |> Selector.tick_running(:goals, false)
      else
        self |> Selector.tick(:targets) |> Selector.tick(:goals)
      end

    self = Navigation.tick(self)

    # `customServerAiStep`: a brain ticks, then its mob picks its activity;
    # a family's mob does its own part; only an adult animal stays in love.
    self =
      case self.mind.brain do
        nil -> self
        %{module: module} -> self |> Valimc.AI.Brain.tick() |> module.update_activity()
      end

    self = hook(self, :custom_step)

    self =
      if animal?(self.type) and self.mind.age != 0,
        do: Self.mind(self, &%{&1 | in_love: 0}),
        else: self

    Look.tick(self)
  end

  # `getLightLevelDependentMagicValue` at the eyes: a blaze is always lit.
  defp light(%Self{type: "minecraft:blaze"}), do: 1.0

  defp light(self),
    do: World.light(self.world, {floor(self.x), floor(Self.eye_y(self)), floor(self.z)})

  defp animal?(type), do: type in ["minecraft:pig"]

  # A family's override of part of vanilla's tick (`Valimc.AI.Kind`).
  defp hook(%Self{type: type} = self, name), do: Mobs.hook(type, name, [self], self)

  @doc """
  After the kernel moved the mob of `entry` (`{id, entry}`, its entity at
  the old position) to `position`: the body rotation control, an animal's
  ageing and love (`AgeableMob.aiStep`, `Animal.aiStep`) and a brain mob's
  looting (`Mob.aiStep`), with its family's hooks around the body control
  (`Valimc.AI.Kind`). `{body, position, effects, world}`: a family may
  teleport it.
  """
  def settle(
        {id, %{entity: e}},
        %Body{mob: %Mob{ai: %Mind{} = mind} = mob} = body,
        {x, y, z},
        world
      ) do
    if Mob.alive?(mob) and thinking?(body) do
      {width, height, eye} = Body.dimensions(body)

      self = %Self{
        id: id,
        uuid: e.uuid,
        type: body.type,
        x: x,
        y: y,
        z: z,
        yaw: body.yaw,
        pitch: body.pitch,
        head: body.head_yaw,
        on_ground: body.on_ground,
        velocity: body.velocity,
        mob: mob,
        mind: mind,
        facts: Facts.mob(body.type),
        width: width,
        height: height,
        eye: eye,
        data: body.data,
        world: world
      }

      # A family's `aiStep` after its super with `Mob.aiStep`'s looting
      # (VMC-043b), the body control, its `tick` after its super
      # (`Valimc.AI.Kind`).
      self =
        self
        |> hook(:after_ai)
        |> Valimc.AI.Pickup.tick()
        |> Look.body({e.x, e.z})
        |> hook(:after_tick)

      # Growing up or toward breeding again, and love running out (its heart
      # particles' draws are VMC-043c's, with breeding).
      self =
        if animal?(body.type) do
          Self.mind(self, fn mind ->
            mind = %{mind | age: mind.age - sign(mind.age)}
            mind = if mind.age != 0, do: %{mind | in_love: 0}, else: mind
            if mind.in_love > 0, do: %{mind | in_love: mind.in_love - 1}, else: mind
          end)
        else
          self
        end

      self =
        case mind.brain do
          nil -> self
          %{module: module} -> module.pick_up(self)
        end

      {%{
         body
         | yaw: self.yaw,
           head_yaw: self.head,
           velocity: self.velocity,
           mob: %{self.mob | ai: self.mind},
           data: self.data
       }, {self.x, self.y, self.z}, Enum.reverse(self.effects), self.world}
    else
      {body, {x, y, z}, [], world}
    end
  end

  def settle(_mob, body, position, world), do: {body, position, [], world}

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(_), do: 0

  @doc """
  What a hurt leaves in a mob's mind (`hurtServer`, VMC-037n's one path):
  not idle, the attacker that angers it with the tick it hit, and the
  damage type the next tick reads (`getLastDamageSource`).
  """
  def hurt(%Mind{} = mind, attacker, source) do
    mind = %{mind | no_action: 0, damage: {source, mind.tick + 1, attacker}}
    if attacker, do: %{mind | hurt_by: {attacker, mind.tick}}, else: mind
  end

  def hurt(mind, _attacker, _source), do: mind

  @doc """
  `getVoicePitch` from the mind's random (the hurt and death sounds), and
  whether the hurt sound resets the ambient timer (`Mob.playHurtSound`):
  `{pitch, mind}`; a mob without a mind draws from the owner's random.
  """
  def voice(%Mind{random: random} = mind, interval, base \\ 1.0) do
    {pitch, random} = Random.voice_pitch(random, base)
    mind = %{mind | random: random}
    {pitch, if(interval, do: %{mind | ambient: -interval}, else: mind)}
  end

  @doc "The ambient interval of a mob of `type` (nil without AI facts)."
  def ambient_interval(type), do: (f = Facts.mob(type)) && f.ambient_interval
end
