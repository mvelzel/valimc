defmodule Valimc.AI do
  @moduledoc """
  Mob AI (VMC-041a), run by the owning group once per section per tick,
  never as a process per mob. `Valimc.Entity.MobTicks` ticks a section's
  mobs one at a time in id order, as vanilla's level does; before a mob
  moves, `think_mob/4` runs its part of vanilla's tick: `checkDespawn`'s
  idle reset near a player, `tickCount`, the expiry of who hurt it,
  `Mob.baseTick`'s ambient sound, a monster's idle time in light, and
  `Mob.serverAiStep`: its target and goal selectors (`Valimc.AI.Selector`:
  a full update on alternate ticks by its id, otherwise only goals updated
  every tick), its navigation and its look control. The kernel then runs the
  move and jump controls with what the AI set; `settle/2` runs the body
  rotation control and an animal's age after the move, and
  `resense_entry/3` shows the moved mob to the mobs after it (`think/2`
  thinks a section's mobs without moving them).

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
  alias Valimc.Entity.{Animal, Body, Mob}

  @doc "Whether mobs of `type` have an AI."
  def thinks?(type), do: Facts.mob(type) != nil and Mobs.goals?(type)

  # A `NoAI` mob runs none of it (`Mob.isEffectiveAi`).
  defp thinking?(%Body{type: type, mob: mob}), do: thinks?(type) and not mob.no_ai

  @doc """
  A mob's mind from what its record kept (`ai`: nil for a new mob, else
  `Mind.record/1`'s map), its random seeded from `uuid` when new. A brain
  mob's brain is made for its body's `data` and gets its saved memories
  back; made in `world`, it starts as its constructor does (`started/2`).
  """
  def mind(type, uuid, kept, data \\ %{}, world \\ nil) do
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
        # A brain made for its body (a villager's for its age, VMC-044a1).
        {brain, random} =
          if exports?(module, :brain, 3),
            do:
              apply(module, :brain, [
                mind.random,
                apply(module, :gates, [uuid, baby?(data)]),
                data
              ]),
            else: module.brain(mind.random, module.gates(uuid))

        memories =
          case kept do
            %{memories: memories} when is_map(memories) -> memories
            _ -> %{}
          end

        mind = %{mind | brain: %{brain | memories: memories}, random: random}

        if world != nil and exports?(module, :started, 1),
          do:
            apply(module, :started, [
              %Self{uuid: uuid, type: type, mind: mind, world: world, data: data}
            ]).mind,
          else: mind
    end
  end

  defp exports?(module, name, arity),
    do: Code.ensure_loaded?(module) and function_exported?(module, name, arity)

  defp baby?(%{age: age}), do: age < 0
  defp baby?(_data), do: false

  @doc """
  What others read of a mob of a section (`Valimc.AI.World`'s sensed mob):
  `{id, entry}` of the store.
  """
  def sensed({id, %{entity: e, body: %Body{type: type, mob: mob} = body}}) do
    {width, height, eye} = Body.dimensions(body)
    mind = match_mind(mob.ai)
    position = {e.x * 1.0, e.y * 1.0, e.z * 1.0}
    animal = Animal.animal?(type)

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
      # A baby by its family's flag (zombies, piglins); a hoglin hunters may
      # hunt (VMC-043d).
      baby: Map.get(body.data, :baby, false),
      huntable: not Map.get(body.data, :cannot_be_hunted, false),
      target: mind && mind.target,
      in_love: if(animal, do: body.data.in_love, else: 0),
      age: if(animal, do: body.data.age, else: 0),
      data: body.data,
      # What its family keeps of its own (a fish's school, VMC-043e).
      own: mind && mind.own,
      panicking:
        mind != nil and
          Valimc.AI.Goals.Panic in Selector.running(%Self{mind: mind}, :goals),
      # What brain mobs read of each other (VMC-044a1): memories, own data,
      # where its path leads now (doors), whether it sleeps.
      memories: mind && mind.brain && mind.brain.memories,
      sleeping: Map.get(body.data, :sleeping),
      path_step: mind && path_step(mind.navigation.path)
    }
  end

  defp path_step(%{nodes: nodes, index: index}) when index > 0 and index < tuple_size(nodes),
    do: {elem(nodes, index - 1), elem(nodes, index)}

  defp path_step(_path), do: nil

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
    {mobs, world, ctx} = prepare(mobs, world)

    {results, {ctx, world}} =
      mobs
      |> Enum.with_index()
      |> Enum.map_reduce({ctx, world}, fn {mob, index}, {ctx, world} ->
        {result, ctx, world} = think_mob(ctx, index, mob, world)
        {result, {ctx, world}}
      end)

    {finish(ctx, results, mobs), world}
  end

  @doc """
  What thinking mobs one by one needs (`think_mob/4`): each mob of `mobs`
  (`[{id, entry}]`, in id order) with a mind, the world sensing them, and
  the context the mobs' changes to one another collect in. `{mobs, world,
  ctx}`.
  """
  def prepare(mobs, %World{} = world) do
    mobs = Enum.map(mobs, fn {id, entry} -> {id, ensure(entry, world)} end)
    sensed = Enum.map(mobs, &sensed/1)

    world = %{
      world
      | mobs: sensed,
        by_type: Enum.group_by(sensed, & &1.type),
        index: Map.new(sensed, &{&1.uuid, &1}),
        moved: %{}
    }

    order = mobs |> Enum.with_index() |> Map.new(fn {{_, e}, i} -> {e.entity.uuid, i} end)
    {mobs, early, world} = react(mobs, order, world)
    {mobs, world, %{order: order, changes: %{}, early: early}}
  end

  @doc """
  The AI part of the tick of mob `index` (`{id, entry}`): the changes
  earlier mobs made to it, then its think. `{{id, body, position, effects},
  ctx, world}`; the world as it left it (others as it changed them, the
  level random).

  Another mob changed at once, as vanilla changes it: a mob later in order
  thinks with it, one earlier keeps it for its next tick.
  """
  def think_mob(%{order: order, changes: changes} = ctx, index, {id, entry}, world) do
    uuid = entry.entity.uuid
    entry = %{entry | body: change(entry.body, changes[uuid])}
    {body, position, effects, world} = think_one(id, entry, world)
    effects = Map.get(ctx.early, id, []) ++ effects

    made =
      for effect <- effects,
          {other, fun, sensed} <- [other_change(effect, world)],
          Map.has_key?(order, other),
          do: {other, fun, sensed}

    # Others read its own state and the changed mobs' as they are now; a
    # brain mob's memories after its tick (VMC-044a1: villagers' claims).
    world =
      if own_of(body) != own_of(entry.body) or made != [] or brain?(body),
        do: World.resense(world, uuid, &Map.merge(&1, sensed_state(body))),
        else: world

    world =
      Enum.reduce(made, world, fn {other, _, sensed}, world ->
        World.resense(world, other, sensed)
      end)

    changes =
      for {other, fun, _} <- made, reduce: changes do
        acc ->
          key = if order[other] > index, do: other, else: {:late, other}
          Map.update(acc, key, [fun], &(&1 ++ [fun]))
      end

    {{id, body, position, effects}, %{ctx | changes: changes}, world}
  end

  @doc """
  The bodies of `results` (`[{id, body, ...}]`, in the order of `mobs`)
  with the changes later mobs made to earlier ones.
  """
  def finish(%{changes: late}, results, mobs) do
    for {result, {_, entry}} <- Enum.zip(results, mobs),
        do: put_elem(result, 1, change(elem(result, 1), late[{:late, entry.entity.uuid}]))
  end

  @doc "The world with mob `uuid` sensed again from its `entry` (after it moved)."
  def resense_entry(%World{} = world, _id, %{entity: e, body: body}) do
    case World.entity(world, {:mob, e.uuid}) do
      nil ->
        world

      sensed ->
        mind = match_mind(body.mob.ai)

        fresh = %{
          sensed
          | x: e.x * 1.0,
            y: e.y * 1.0,
            z: e.z * 1.0,
            yaw: body.yaw,
            pitch: body.pitch,
            alive: Mob.alive?(body.mob),
            target: mind && mind.target
        }

        %{world | moved: Map.put(world.moved, e.uuid, Map.merge(fresh, sensed_state(body)))}
    end
  end

  # What an effect changes in another mob, and in what others sense of it:
  # an alert sets its target, a breeding its age and love, a family's change
  # its own state (a school's leader and size, VMC-043e).
  defp other_change({:alert, uuid, target}, world),
    do: {uuid, fn body -> alerted(body, uuid, target, world) end, & &1}

  defp other_change({:bred, {:mob, uuid}}, _world) do
    fun = fn body -> %{body | data: Animal.bred(body.data)} end

    {uuid, fun,
     fn sensed ->
       Map.merge(sensed, sensed_state(fun.(%Body{type: sensed.type, data: sensed.data})))
     end}
  end

  defp other_change({:own, uuid, change}, _world),
    do: {uuid, &own_body(&1, change), fn sensed -> %{sensed | own: change.(sensed.own)} end}

  # A brain mob's change of another's memories (VMC-044a1: a villager
  # yielding its job site, gossip, a golem seen): `fun` on its mind.
  defp other_change({:remote, uuid, fun}, _world),
    do:
      {uuid,
       fn
         %Body{mob: %Mob{ai: %Mind{} = mind} = mob} = body ->
           %{body | mob: %{mob | ai: fun.(mind)}}

         body ->
           body
       end, & &1}

  defp other_change(_effect, _world), do: nil

  defp change(body, nil), do: body
  defp change(body, funs), do: Enum.reduce(funs, body, & &1.(&2))

  # What others sense of a mob's state beyond its place.
  defp sensed_state(%Body{type: type, data: data} = body) do
    own = %{own: own_of(body)}

    own =
      case body do
        # What brain mobs read of each other (VMC-044a1): memories, own data,
        # whether it sleeps.
        %Body{mob: %Mob{ai: %Mind{brain: %{memories: memories}}}} ->
          Map.merge(own, %{memories: memories, data: data, sleeping: Map.get(data, :sleeping)})

        _ ->
          own
      end

    if Animal.animal?(type),
      do: Map.merge(own, %{in_love: data.in_love, age: data.age, data: data}),
      else: own
  end

  defp brain?(%Body{mob: %Mob{ai: %Mind{brain: %{}}}}), do: true
  defp brain?(_body), do: false

  # A brain mob's reactions before its section thinks (VMC-043d): to the
  # entities that hurt it since it last thought (`wasHurtBy`, which vanilla
  # runs as the hurt lands) and to what players did (`angerNearbyPiglins`),
  # each with what it changes in other mobs' brains (`{:brain, uuid, fun}`)
  # applied at once. `{mobs, early effects by id, world}`.
  defp react(mobs, order, %World{} = world) do
    tuple = List.to_tuple(mobs)

    {tuple, early, world} =
      Enum.reduce(0..(tuple_size(tuple) - 1)//1, {tuple, %{}, world}, fn index, acc ->
        react_one(index, acc, order)
      end)

    {Tuple.to_list(tuple), early, %{world | events: []}}
  end

  defp react_one(index, {tuple, early, world} = acc, order) do
    {id, entry} = elem(tuple, index)

    with %Body{mob: %Mob{ai: %Mind{brain: %{module: module}} = mind} = mob} <- entry.body,
         true <- Mob.alive?(mob),
         true <- reacts?(module),
         events when events != [] <- mind.pending ++ world.events do
      entry = put_in(entry.body.mob.ai.pending, [])
      self = self_of(id, entry, world)
      self = Enum.reduce(events, self, &module.react(&2, &1))
      {others, own} = Enum.split_with(self.effects, &match?({:brain, _, _}, &1))
      tuple = put_elem(tuple, index, {id, %{entry | body: settled(entry.body, self)}})
      early = Map.update(early, id, Enum.reverse(own), &(&1 ++ Enum.reverse(own)))

      others
      |> Enum.reverse()
      |> Enum.reduce({tuple, early, self.world}, fn {:brain, uuid, fun}, {tuple, early, world} ->
        case order[uuid] do
          nil ->
            {tuple, early, world}

          other ->
            {other_id, other_entry} = elem(tuple, other)

            if match?(%Body{mob: %Mob{ai: %Mind{brain: %{}}}}, other_entry.body) do
              them = fun.(self_of(other_id, other_entry, world))
              entry = %{other_entry | body: settled(other_entry.body, them)}
              made = Enum.reverse(them.effects)

              {put_elem(tuple, other, {other_id, entry}),
               Map.update(early, other_id, made, &(&1 ++ made)), them.world}
            else
              {tuple, early, world}
            end
        end
      end)
    else
      _ -> acc
    end
  end

  defp reacts?(module), do: Code.ensure_loaded?(module) and function_exported?(module, :react, 2)

  # The mob as its AI sees it, outside its own think (a reaction).
  defp self_of(id, %{entity: e, body: %Body{type: type, mob: mob} = body}, world) do
    {width, height, eye} = Body.dimensions(body)

    %Self{
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
  end

  defp settled(body, %Self{} = self),
    do: %{body | mob: %{self.mob | ai: self.mind}, data: self.data}

  defp own_of(%Body{mob: %Mob{ai: %Mind{own: own}}}), do: own
  defp own_of(_body), do: nil

  defp own_body(%Body{mob: %Mob{ai: %Mind{} = mind} = mob} = body, change),
    do: %{body | mob: %{mob | ai: %{mind | own: change.(mind.own)}}}

  defp own_body(body, _change), do: body

  # A mob of a type with an AI thinks with a mind (from its record, or new).
  defp ensure(
         %{entity: e, body: %Body{type: type, mob: %Mob{ai: ai} = mob} = body} = entry,
         world
       ) do
    if thinks?(type) and not match?(%Mind{}, ai),
      do: %{entry | body: %{body | mob: %{mob | ai: mind(type, e.uuid, ai, body.data, world)}}},
      else: entry
  end

  # Another mob's alert sets the target through the type's `setTarget`.
  defp alerted(%Body{type: type, mob: %Mob{ai: %Mind{} = mind} = mob} = body, uuid, target, world) do
    self =
      Self.set_target(%Self{type: type, uuid: uuid, mob: mob, mind: mind, world: world}, target)

    %{body | mob: %{mob | ai: self.mind}}
  end

  defp alerted(body, _uuid, _target, _world), do: body

  defp think_one(id, %{entity: e, body: %Body{} = body}, world) do
    # A mob still to finalize its spawn does so first (VMC-043b), with or
    # without goals.
    {body, made, world} = finalize(id, e, body, world)
    %Body{type: type, mob: mob} = body

    if not thinks?(type) or not match?(%Mind{}, mob.ai) or
         not (Mob.alive?(mob) or dying?(type)) do
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
        data: body.data,
        mind: mob.ai,
        facts: Facts.mob(type),
        width: width,
        height: height,
        eye: eye,
        world: world
      }

      # A family's `tick` before its super, and its `aiStep` before its
      # super (`Valimc.AI.Kind`). A `NoAI` mob still despawns, ticks and
      # plays its ambient sound; only its `serverAiStep` is skipped. A dying
      # mob of a family that ticks while dying (`dying?/0`) runs only its
      # own `tick` and `aiStep` (a dead fish still flops); one that dies in
      # its base tick is immobile. A mob its tick's start converted (a
      # skeleton freezing, VMC-043b) is gone: the rest of its tick does not
      # run.
      self =
        if Mob.alive?(mob) do
          self = self |> despawn_check() |> hook(:tick_start)

          if Enum.any?(self.effects, &(match?({:convert, _}, &1) or &1 == :discard)) do
            self
          else
            self = self |> base_tick() |> own_air() |> using_item()

            cond do
              not Mob.alive?(self.mob) -> hook(self, :before_ai)
              mob.no_ai or not world.goals -> hook(self, :before_ai)
              true -> self |> hook(:before_ai) |> ai_step()
            end
          end
        else
          self |> hook(:tick_start) |> hook(:before_ai)
        end

      motion = %{self.mob.motion | jump: self.mind.jump, rise: self.mind.rise}
      mob = %{self.mob | ai: self.mind, motion: motion}
      mob = %{mob | ai: %{mob.ai | jump: false, rise: false}}

      {%{
         body
         | yaw: self.yaw,
           pitch: self.pitch,
           head_yaw: self.head,
           velocity: self.velocity,
           on_ground: self.on_ground,
           mob: mob,
           data: self.data
       }, {self.x, self.y, self.z}, made ++ Enum.reverse(self.effects), self.world}
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
        world: world,
        data: body.data
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
    # `LivingEntity.baseTick` starts with its swing; `Entity.baseTick` ends
    # with the lead (VMC-043c3).
    self =
      self
      |> Self.mind(&%{&1 | tick: &1.tick + 1, swing: Self.swing_tick(&1.swing)})
      |> Valimc.AI.Leash.tick()

    # `LivingEntity.baseTick`'s air, where a family keeps its own (a
    # dolphin's), before `Mob.baseTick`'s ambient sound.
    self = put_air(self, Mobs.hook(self.type, :breath, [self], nil))

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

    # `LivingEntity.baseTick` ends with `tickEffects` (VMC-044a4): the
    # mob's effects run down (their periodic actions on mobs are not
    # modelled yet), before `Mob.baseTick`'s ambient sound.
    self = tick_effects(self)

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

  # A family's sound may draw on the mob's random (a resting bat's).
  defp ambient_sound(%Self{facts: facts} = self) do
    case Mobs.hook(self.type, :ambient_sound, [self], facts.ambient_sound) do
      {name, %Self{} = self} -> make_sound(self, name)
      name -> make_sound(self, name)
    end
  end

  @doc """
  `LivingEntity.makeSound`: sound `name` (or its id; nil plays none) at the mob's
  volume and voice pitch (a baby's higher), drawn from its random.
  """
  def make_sound(self, nil), do: self

  def make_sound(%Self{facts: facts} = self, name) do
    {pitch, random} = Random.voice_pitch(self.mind.random, Mobs.voice(self.type, self.data))
    self = Self.mind(self, &%{&1 | random: random})
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    id = if is_integer(name), do: name, else: Facts.sound_id(name)
    Self.effect(self, {:sound, id, source(self.type), facts.volume, pitch, seed})
  end

  @doc "`Entity.playSound(name, volume, pitch)` at the mob, a pitch of its own (no draw)."
  def play(%Self{type: type} = self, name, volume \\ 1.0, pitch \\ 1.0) do
    <<seed::signed-64>> = :crypto.strong_rand_bytes(8)

    Self.effect(
      self,
      {:sound, Facts.sound_id(name), source(type), Valimc.Data.Float32.round(volume),
       Valimc.Data.Float32.round(pitch), seed}
    )
  end

  defp source(type), do: Valimc.Protocol.CombatPackets.mob_sounds(type)["sound_source"]

  # `MoveControl.tick`'s strafe check, as the move control runs it next
  # (VMC-043b): a step that would not land on a walkable block goes straight
  # ahead instead.
  defp strafe(%Self{mob: %{motion: %{control: {:strafe, forward, right, modifier}}}} = self) do
    alias Valimc.Data.Float32
    speed = Float32.round(Mob.value(self.type, self.mob, "minecraft:movement_speed"))
    modified = Float32.round(Float32.round(modifier) * speed)
    dist = max(Float32.round(:math.sqrt(Float32.round(forward * forward + right * right))), 1.0)
    dist = Float32.round(modified / dist)
    {xa, za} = {Float32.round(forward * dist), Float32.round(right * dist)}
    radians = Float32.round(self.yaw * Float32.round(:math.pi() / 180.0))
    {sin, cos} = {Valimc.Data.Mth.sin(radians), Valimc.Data.Mth.cos(radians)}
    dx = Float32.round(Float32.round(xa * cos) - Float32.round(za * sin))
    dz = Float32.round(Float32.round(za * cos) + Float32.round(xa * sin))
    cell = {floor(self.x + dx), floor(self.y), floor(self.z + dz)}

    if Valimc.AI.RandomPos.static(self.world, cell) == :walkable,
      do: self,
      else: Self.strafe(self, 1.0, 0.0)
  end

  defp strafe(self), do: self

  @instant_health Valimc.Data.EffectTypes.id("instant_health")

  defp tick_effects(%Self{mob: %{living: %{effects: effects} = living} = mob} = self)
       when map_size(effects) > 0 do
    # Instant health (a witch's drink, VMC-043b6) heals as it ticks.
    living =
      case effects[@instant_health] do
        [{duration, amplifier, _, _, _} | _] when duration >= 1 ->
          {:ok, {:heal, amount}} = Valimc.Living.Effects.instant(@instant_health, amplifier)
          {:ok, health} = Valimc.Living.Health.heal(living.health, amount)
          %{living | health: health}

        _ ->
          living
      end

    mob = %{mob | living: living}
    self = %{self | mob: mob}

    case Valimc.Living.Effects.tick(effects) do
      {:ok, effects, _} -> %{self | mob: %{mob | living: %{living | effects: effects}}}
      _ -> self
    end
  end

  defp tick_effects(self), do: self

  # `updatingUsingItem` (VMC-043b): an item still in its hand counts another
  # tick of use; one that left it stops. A drink (VMC-044a4) plays its sound
  # now and then and is drunk when its use is up (`updateUsingItem`).
  defp using_item(%Self{mob: %{using: {hand, ticks}} = mob} = self) do
    slot = if hand == :off_hand, do: :offhand, else: :mainhand

    case mob.equipment[slot] do
      nil ->
        Self.stop_using(self)

      stack ->
        self = %{self | mob: %{mob | using: {hand, ticks + 1}}}
        Valimc.AI.Consume.tick(self, slot, stack, ticks)
    end
  end

  defp using_item(self), do: self

  # `LivingEntity.aiStep` up to the move: a `Monster`'s idle time in light,
  # then `serverAiStep`.
  defp ai_step(%Self{} = self) do
    self =
      if monster?(self) and light(self) > 0.5,
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

    # A goal that moved the mob itself (`BreathAirGoal`): the rest of its AI
    # reads where that move took it; the kernel moves it from where it was.
    {self, at} =
      case Valimc.AI.Goals.BreathAir.predicted(self) do
        nil -> {self, nil}
        {x, y, z} -> {%{self | x: x, y: y, z: z}, {self.x, self.y, self.z}}
      end

    self = Navigation.tick(self)

    # `customServerAiStep`: a brain ticks, then its mob picks its activity;
    # a family's mob does its own part (an animal's love, a rabbit's hops).
    self =
      case self.mind.brain do
        nil -> self
        %{module: module} -> self |> Valimc.AI.Brain.tick() |> module.update_activity()
      end

    self = hook(self, :custom_step)
    # A family's own move control (a fish's) runs before the look control.
    self = hook(self, :move_control)
    # A family without a look control (a phantom's) keeps its rotations.
    self = strafe(self)
    self = if Mobs.hook(self.type, :looks?, [], true), do: Look.tick(self), else: self

    case at do
      nil -> self
      {x, y, z} -> %{self | x: x, y: y, z: z}
    end
  end

  # `getLightLevelDependentMagicValue` at the eyes: a blaze is always lit.
  defp light(%Self{type: "minecraft:blaze"}), do: 1.0

  defp light(self),
    do: World.light(self.world, {floor(self.x), floor(Self.eye_y(self)), floor(self.z)})

  # `instanceof Monster` (not a ghast or a cube), by its facts where it has them.
  defp monster?(%Self{facts: %{monster: monster}}), do: monster
  defp monster?(self), do: EntityTypes.fetch(self.type).category == :monster

  # A family's override of part of vanilla's tick (`Valimc.AI.Kind`).
  defp hook(%Self{type: type} = self, name), do: Mobs.hook(type, name, [self], self)

  # A water animal's air after its base tick (`WaterAnimal.baseTick`): in
  # water as it began the tick, or drowning; its hurt (as a dolphin's own
  # `breath/1` in the base tick) goes through the one hurt path, which
  # leaves the hurt in its mind.
  defp own_air(%Self{type: type, mob: mob} = self),
    do: put_air(self, Mobs.hook(type, :air, [mob.living.air_supply, Self.in_water?(self)], nil))

  defp put_air(self, nil), do: self

  defp put_air(%Self{type: type, mob: mob} = self, result) do
    case result do
      {air, damage} ->
        {mob, events} =
          Valimc.Entity.MobVitals.set_air(
            %{type: type, data: self.data},
            %{mob | ai: self.mind},
            air,
            damage
          )

        self = %{self | mob: %{mob | ai: nil}, mind: mob.ai}
        Enum.reduce(events, self, &Self.effect(&2, &1))
    end
  end

  @doc """
  After the kernel moved the mob of `entry` (`{id, entry}`, its entity at
  the old position) to `position`: the body rotation control, an animal's
  ageing and love (`AgeableMob.aiStep`, `Animal.aiStep`) and a brain mob's
  looting (`Mob.aiStep`), with its family's hooks around the body control
  (`Valimc.AI.Kind`). `{body, position, effects, world}`: a family may
  teleport it.
  """
  def settle(mob, body, position, world, swim \\ nil)

  def settle(
        {id, %{entity: e}},
        %Body{mob: %Mob{ai: %Mind{} = mind} = mob} = body,
        {x, y, z},
        world,
        swim
      ) do
    alive = Mob.alive?(mob)

    if thinking?(body) and (alive or dying?(body.type)) do
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
        world: world,
        data: body.data
      }

      # The swim sound its move made, then a family's `aiStep` after its
      # super with `Mob.aiStep`'s looting (VMC-043b), the body control, its
      # `tick` after its super (`Valimc.AI.Kind`); a dying mob's own only.
      self =
        if alive,
          do:
            self
            |> swim(swim)
            |> hook(:after_ai)
            |> Valimc.AI.Pickup.tick()
            |> Look.body(mind.snapped || {e.x, e.z})
            |> Self.mind(&%{&1 | snapped: nil})
            |> hook(:after_tick)
            |> Valimc.AI.Leash.control_flags(),
          else: self |> swim(swim) |> hook(:after_ai) |> hook(:after_tick)

      self =
        case alive && mind.brain do
          %{module: module} -> module.pick_up(self)
          _ -> self
        end

      {%{
         body
         | yaw: self.yaw,
           head_yaw: self.head,
           velocity: self.velocity,
           on_ground: self.on_ground,
           mob: %{self.mob | ai: self.mind},
           data: self.data
       }, {self.x, self.y, self.z}, Enum.reverse(self.effects), self.world}
    else
      still({id, e}, body, {x, y, z}, world)
    end
  end

  def settle(_mob, body, position, world, _swim), do: {body, position, [], world}

  # Whether a dying mob of `type` still runs its family's own tick (a fish's
  # flop).
  defp dying?(type), do: Mobs.hook(type, :dying?, [], false)

  # `playSwimSound(volume)`: its pitch from the mob's random (a goal's own
  # move's first).
  defp swim(self, volumes) when is_list(volumes), do: Enum.reduce(volumes, self, &swim(&2, &1))
  defp swim(self, nil), do: self

  defp swim(%Self{type: type} = self, volume) do
    if Valimc.Entity.MobMotion.sounds?(type) do
      {a, self} = Self.float(self)
      {b, self} = Self.float(self)
      f = &Valimc.Data.Float32.round/1
      pitch = f.(1.0 + f.(f.(a - b) * f.(0.4)))
      <<seed::signed-64>> = :crypto.strong_rand_bytes(8)
      name = Mobs.hook(type, :swim_sound, [], default_swim(type))
      Self.effect(self, {:sound, Facts.sound_id(name), source(type), volume, pitch, seed})
    else
      self
    end
  end

  # `getSwimSound`: a monster's, else the generic one.
  defp default_swim(type),
    do:
      if(EntityTypes.fetch(type).category == :monster,
        do: "minecraft:entity.hostile.swim",
        else: "minecraft:entity.generic.swim"
      )

  # A living animal without an AI still ages and loses its love
  # (`AgeableMob.aiStep` runs for a `NoAI` mob: its family's `after_ai`).
  defp still({id, e}, %Body{mob: %Mob{ai: mind} = mob} = body, {x, y, z}, world) do
    if Mob.alive?(mob) and Animal.animal?(body.type) do
      {width, height, eye} = Body.dimensions(body)

      self =
        hook(
          %Self{
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
            mob: mob,
            mind: mind,
            facts: Facts.mob(body.type),
            width: width,
            height: height,
            eye: eye,
            world: world,
            data: body.data,
            velocity: body.velocity
          },
          :after_ai
        )

      {%{body | mob: %{self.mob | ai: self.mind}, data: self.data, velocity: self.velocity},
       {x, y, z}, Enum.reverse(self.effects), self.world}
    else
      {body, {x, y, z}, [], world}
    end
  end

  @doc """
  What a hurt leaves in a mob's mind (`hurtServer`, VMC-037n's one path):
  not idle, the attacker that angers it with the tick it hit, and the
  damage type the next tick reads (`getLastDamageSource`).
  """
  def hurt(%Mind{} = mind, attacker, source) do
    mind = %{mind | no_action: 0, damage: {source, mind.tick + 1, attacker}}

    # A brain mob reacts to its attacker before its section next thinks.
    mind =
      if attacker != nil and mind.brain != nil,
        do: %{mind | pending: mind.pending ++ [{:hurt_by, attacker}]},
        else: mind

    if attacker, do: %{mind | hurt_by: {attacker, mind.tick}}, else: mind
  end

  def hurt(mind, _attacker, _source), do: mind

  @doc """
  `getVoicePitch` from the mind's random (the hurt and death sounds, a
  baby's higher), and
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
