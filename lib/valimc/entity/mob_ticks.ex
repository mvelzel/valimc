defmodule Valimc.Entity.MobTicks do
  @moduledoc """
  One tick of an owner's mobs (VMC-015i), one mob at a time in id order as
  vanilla's level ticks them, so each thinks with the mobs before it where
  they moved to (VMC-043e): its AI (`Valimc.AI.think_mob/4`, VMC-041a), its
  travel in the physics kernel (`Valimc.Physics.Kernel.mobs/4`: the move
  and jump controls, travel, collision, fluids, climbing, slowing blocks),
  its pushes (by the players it touches, and of the mobs it touches, which
  push it back), then its body rotation and looting (`Valimc.AI.settle/4`)
  and living rules (`Valimc.Entity.MobVitals`); the players push last. The
  result is a store step per mob: its position, its new body, its entity
  events and what its AI did beyond it (`effects`, with farmland it
  trampled, VMC-039a); a mob the kernel could not tick (near a chunk it
  cannot read) has none.
  """
  alias Valimc.AI
  alias Valimc.Data.Float32
  alias Valimc.Entity.{MobMotion, MobVitals}
  alias Valimc.Physics.Kernel

  @doc """
  The steps of `mobs` (`[{id, entry}]`, in id order) over `view` and
  `border`, with the AI's `world` (`Valimc.AI.World`: its players push the
  mobs they touch): `{steps, world}`, the world as the mobs left it.
  """
  def steps(view, mobs, world, border, external \\ [])
  def steps(_view, [], world, _border, _external), do: {[], world}

  def steps(view, mobs, %AI.World{} = world, border, external) do
    external = collider_neighbors(mobs, external)
    {mobs, world, ctx} = AI.prepare(mobs, world)
    old = Map.new(mobs)
    ids = mobs |> Enum.map(&elem(&1, 0)) |> List.to_tuple()
    index = Map.new(Enum.with_index(Tuple.to_list(ids)))

    # A player's standing box pushes the mobs it touches.
    players =
      for %{x: x, y: y, z: z} <- world.players,
          do: {{x, y, z}, {x - 0.3, y, z - 0.3, x + 0.3, y + 1.8, z + 0.3}}

    # Mobs of a type without overrides share their travel attributes.
    {inputs, travel} =
      Enum.map_reduce(mobs, %{}, fn {_, entry}, travel -> input(entry, travel) end)

    # Other sections of the same group are stable while this section
    # ticks. Their fixed solid families join the grid without being ticked.
    {other_inputs, travel} =
      Enum.map_reduce(external, travel, fn {_, entry}, travel ->
        {input, travel} = input(entry, travel)

        {Map.merge(input, %{
           fixed: true,
           pushable: false,
           pushes: false,
           velocity: {0.0, 0.0, 0.0}
         }), travel}
      end)

    colliders =
      for {{_, entry}, i} <- Enum.with_index(mobs ++ external),
          box = collider_box(entry, :unsupported),
          box != :unsupported,
          do: {i, box}

    ticker = Kernel.mobs_begin(view, inputs ++ other_inputs, players, border, colliders)

    state = %{
      entries: Map.new(mobs),
      ids: ids,
      index: index,
      by_uuid: Map.new(mobs, fn {id, entry} -> {entry.entity.uuid, id} end),
      ctx: ctx,
      world: world,
      travel: travel,
      steps: [],
      pending: %{},
      solid: MapSet.new(colliders, &elem(&1, 0))
    }

    state =
      mobs
      |> Enum.with_index()
      |> Enum.reduce(state, fn {{id, _}, i}, state -> step(view, ticker, old, id, i, state) end)

    velocities = ticker |> Kernel.mobs_finish() |> List.to_tuple()
    steps = Enum.reverse(state.steps)

    # The alerts later mobs left earlier ones; each mob's motion with every
    # push after it moved.
    steps =
      state.ctx
      |> AI.finish(
        Enum.map(steps, &{&1.id, &1.body}),
        Enum.map(steps, &{&1.id, old[&1.id]})
      )
      |> Enum.zip(steps)
      |> Enum.map(fn {{id, body}, step} ->
        # The dragon skipped ordinary travel; its actor owns the flight
        # velocity. The fixed kernel row only excludes it from pushing.
        body =
          if body.type == "minecraft:ender_dragon",
            do: body,
            else: %{body | velocity: elem(velocities, index[id])}

        %{step | body: body}
      end)

    {steps, state.world}
  end

  defp collider_neighbors(_mobs, []), do: []

  defp collider_neighbors(mobs, external) do
    own = MapSet.new(mobs, &elem(&1, 0))
    # No admitted move exceeds 64 per axis. Include a solid family's
    # extent and step-up before restricting the extra snapshot rows.
    {x0, y0, z0, x1, y1, z1} =
      mobs
      |> Enum.map(fn {_, %{entity: e, body: body}} ->
        Valimc.Entity.Body.box(body, {e.x, e.y, e.z})
      end)
      |> Enum.reduce(fn {a, b, c, d, e, f}, {g, h, i, j, k, l} ->
        {min(a, g), min(b, h), min(c, i), max(d, j), max(e, k), max(f, l)}
      end)

    reach = {x0 - 66, y0 - 66, z0 - 66, x1 + 66, y1 + 66, z1 + 66}

    for {id, %{kind: :mob} = entry} <- external,
        not MapSet.member?(own, id),
        box = collider_box(entry, nil),
        box != nil,
        Valimc.Data.Box.intersects?(reach, box),
        do: {id, entry}
  end

  defp collider_box(%{entity: e, body: body}, default) do
    AI.Mobs.hook(body.type, :collider, [body, {e.x * 1.0, e.y * 1.0, e.z * 1.0}], default)
  end

  defp sync_collider(ticker, state, i, %{entity: e} = entry) do
    if MapSet.member?(state.solid, i),
      do: Kernel.mob_collider(ticker, i, {e.x, e.y, e.z}, collider_box(entry, nil))
  end

  defp input(%{entity: e, body: body}, travel) do
    key = {body.type, body.mob.attributes}

    {attributes, travel} =
      case travel do
        %{^key => attributes} ->
          {attributes, travel}

        _ ->
          attributes = MobMotion.travel(body.type, body.mob.attributes)
          {attributes, Map.put(travel, key, attributes)}
      end

    {MobMotion.kernel(body.type, {e.x * 1.0, e.y * 1.0, e.z * 1.0}, body, attributes), travel}
  end

  # One mob's turn, as vanilla's level ticks it: it thinks (seeing the mobs
  # before it where they moved to), travels and pushes in the ticker, then
  # finishes its tick.
  defp step(view, ticker, old, id, i, state) do
    if state.entries[id].body.type == "minecraft:ender_dragon",
      do: dragon_step(ticker, id, i, state),
      else: ordinary_step(view, ticker, old, id, i, state)
  end

  defp dragon_step(ticker, id, i, %{entries: entries} = state) do
    entry = entries[id]

    {body, position, events, effects} =
      if match?(%{world_tick: tick} when tick == state.world.time, entry.body.data.brain) do
        {Valimc.AI.Dragon.Actor.resume(entry.body, entry.entity),
         {entry.entity.x, entry.entity.y, entry.entity.z}, [], []}
      else
        env = Valimc.AI.Dragon.Actor.environment(entry.body, entry.entity, state.world)
        Valimc.AI.Dragon.Actor.tick(entry.body, entry.entity, env)
      end

    {x, y, z} = position
    entry = %{entry | body: body, entity: %{entry.entity | x: x, y: y, z: z}}
    {effects, state} = melee(ticker, id, entry, effects, state)
    Kernel.mob_velocity(ticker, i, body.velocity)

    step = %{
      id: id,
      revision: entry.revision,
      position: position,
      body: body,
      events: Map.get(state.pending, id, []) ++ events,
      effects: effects
    }

    %{
      state
      | entries: Map.put(state.entries, id, entry),
        steps: [step | state.steps],
        world: AI.resense_entry(state.world, id, entry)
    }
  end

  defp goal_position(ticker, i, entry, travel, self) do
    body = %{
      entry.body
      | mob: %{self.mob | ai: self.mind},
        data: self.data,
        yaw: self.yaw,
        pitch: self.pitch,
        head_yaw: self.head,
        velocity: self.velocity,
        on_ground: self.on_ground
    }

    entry = %{entry | body: body, entity: %{entry.entity | x: self.x, y: self.y, z: self.z}}
    {input, _} = input(entry, travel)
    Kernel.mob_goal_position(ticker, i, input)
  end

  defp ordinary_step(view, ticker, old, id, i, state) do
    entry = sense_fluids(view, state.entries[id])
    # `baseTick`'s burning comes first (VMC-043b).
    {body, burnt} = MobVitals.base_tick(entry.body.type, entry.body)
    entry = %{entry | body: body}

    world = %{
      state.world
      | melee: &kills?(state, id, entry, &1, &2),
        goal_position: &goal_position(ticker, i, entry, state.travel, &1)
    }

    {{^id, body, {x, y, z}, effects}, ctx, world} =
      AI.think_mob(state.ctx, i, {id, entry}, world)

    world = %{world | melee: nil, goal_position: nil}

    entry = %{entry | body: body, entity: %{entry.entity | x: x, y: y, z: z}}
    state = %{state | ctx: ctx, world: world}
    {effects, state} = melee(ticker, id, entry, effects, state)
    {input, travel} = input(entry, state.travel)
    state = %{state | travel: travel}
    sync_collider(ticker, state, i, entry)
    {result, pushed} = Kernel.mob_step(ticker, i, input)

    # The mobs it pushed carry their new motion into their own turns.
    entries =
      Enum.reduce(pushed, state.entries, fn {j, velocity}, entries ->
        other = elem(state.ids, j)
        e = entries[other]
        Map.put(entries, other, %{e | body: %{e.body | velocity: velocity}})
      end)

    state = %{state | entries: entries}

    case result do
      {:ok, ticked} ->
        {made, rest} = split(effects)
        # A family that never falls (a bat's `checkFallDamage`) lands softly.
        ticked =
          if AI.Mobs.hook(entry.body.type, :falls?, [], true),
            do: ticked,
            else: %{ticked | landing: nil}

        {body, position} =
          MobMotion.apply(
            entry.body,
            ticked.mob,
            ticked.depths,
            ticked.powder_snow,
            ticked.eye_after,
            ticked.support
          )

        body = put_in(body.mob.motion.eye_water, ticked.eye_water)
        # The move's splash into water comes before the rest of its tick.
        {body, sounds} = AI.move_sounds(body, ticked.splash)

        # Turtle eggs it fell or stepped on may crack (level random).
        {cracked, world} = eggs(body, ticked, state.world)

        {body, position, settled, world} =
          AI.settle({id, old[id]}, body, position, world, %{
            swims: [ticked.pre_swim, ticked.swim],
            step: ticked.step
          })

        # A family that set its motion after the move (a squid's stroke)
        # tells the ticker, so later pushes add to it.
        if body.velocity != ticked.mob.velocity,
          do: Kernel.mob_velocity(ticker, i, body.velocity)

        {body, events} = MobVitals.apply(body.type, body, ticked)
        events = sounds ++ events
        # The sun on undead mobs and rain on burning ones (VMC-043b).
        {body, sunned} = Valimc.AI.Daylight.tick(body, position, world)
        # A family's own tick after the move (a zombie drowning, VMC-043b).
        {body, own} = AI.Mobs.after_move(body, position, ticked)
        {later, more} = split(settled ++ own)
        {crack_sounds, cracks} = split(cracked)
        {px, py, pz} = position
        entry = %{entry | body: body, entity: %{entry.entity | x: px, y: py, z: pz}}
        sync_collider(ticker, state, i, entry)
        {more, state} = lid_pushes(ticker, more, %{state | world: world})
        world = state.world

        step = %{
          id: id,
          revision: entry.revision,
          position: position,
          body: body,
          events:
            Map.get(state.pending, id, []) ++
              burnt ++ made ++ events ++ sunned ++ later ++ crack_sounds,
          effects: rest ++ more ++ trample(body, ticked) ++ cracks
        }

        step =
          case body.mob.ai do
            %AI.Mind{no_action: idle} -> Map.put(step, :idle, idle)
            _ -> step
          end

        %{
          state
          | entries: Map.put(state.entries, id, entry),
            world: AI.resense_entry(world, id, entry),
            steps: [step | state.steps]
        }

      _ ->
        state
    end
  end

  # The opening lid acts before the next entity ticks. Its displaced target
  # keeps its own turn, and an already-ticked target's returned step is amended.
  defp lid_pushes(ticker, effects, state) do
    Enum.map_reduce(effects, state, fn
      {:shulker_push, area, delta}, state ->
        state =
          Enum.reduce(state.entries, state, fn {id, _}, state ->
            entry = state.entries[id]

            if Valimc.Entity.Displacement.meets?(entry, area) do
              {input, travel} = input(entry, state.travel)

              case Kernel.mob_displace(ticker, state.index[id], input, delta) do
                {:ok, result} ->
                  entry = Valimc.Entity.Displacement.apply(entry, result)
                  {x, y, z} = result |> elem(0)

                  steps =
                    Enum.map(state.steps, fn
                      %{id: ^id} = step -> %{step | body: entry.body, position: {x, y, z}}
                      step -> step
                    end)

                  %{
                    state
                    | entries: Map.put(state.entries, id, entry),
                      steps: steps,
                      travel: travel,
                      world: AI.resense_entry(state.world, id, entry)
                  }

                _ ->
                  state
              end
            else
              state
            end
          end)

        # The owner forwards to all bodies outside this phase and its players.
        {{:shulker_push, area, delta, Map.keys(state.entries)}, state}

      effect, state ->
        {effect, state}
    end)
  end

  # Its melee hits on mobs of this tick land at once, as `doHurtTarget`
  # lands them mid-tick (VMC-043e: an axolotl's prey): the target ticks
  # (or ticked) hurt, its knockback in the ticker before any push; a hit on
  # a mob elsewhere stays an effect for the region.
  defp melee(ticker, id, entry, effects, state) do
    # The phase's membership and ticker positions stay fixed while bodies
    # move and are hurt. Reuse their indexes for every mob's effects.
    index = state.index
    by_uuid = state.by_uuid

    Enum.flat_map_reduce(effects, state, fn
      {:dragon_contact, {:mob, uuid}, push, amount, wing}, state when is_map_key(by_uuid, uuid) ->
        target = by_uuid[uuid]
        target_entry = state.entries[target]
        recent = wing and Valimc.AI.Dragon.Actor.recent?(target_entry.body)
        pushed = Valimc.Entity.Body.push(target_entry.body, push)

        {body, events, hurt} =
          if amount > 0.0 and not recent,
            do:
              Valimc.Entity.Combat.hit_body(
                pushed,
                target_entry.entity,
                Valimc.AI.Dragon.Actor.hit(entry.entity, amount)
              ),
            else: {pushed, [], false}

        body =
          if hurt and not Enum.any?(state.steps, &(&1.id == target)), do: timers(body), else: body

        Kernel.mob_velocity(ticker, index[target], body.velocity)
        {[], hurt(state, ticker, target, %{target_entry | body: body}, events)}

      {:attack, {:mob, uuid}} = effect, state when is_map_key(by_uuid, uuid) ->
        target = by_uuid[uuid]
        target_entry = state.entries[target]
        store = %{entries: %{id => attacker(id, entry)}}

        case Valimc.Entity.Combat.mob_hit(store, id, target_entry.body.type) do
          {:ok, hit} ->
            # What its family adds to the hit (an iron golem's, VMC-044a2).
            hit = Map.merge(hit, extras(effects, uuid))

            {body, events, hurt} =
              Valimc.Entity.Combat.hit_body(target_entry.body, target_entry.entity, hit)

            # One still to tick runs its hurt and death timers this tick
            # (`baseTick`), as the owner's ageing ran them for the rest.
            body =
              if hurt and not Enum.any?(state.steps, &(&1.id == target)),
                do: timers(body),
                else: body

            Kernel.mob_velocity(ticker, index[target], body.velocity)
            {[], hurt(state, ticker, target, %{target_entry | body: body}, events)}

          _ ->
            {[effect], state}
        end

      effect, state ->
        {[effect], state}
    end)
  end

  # Whether mob `id`'s melee hit on `ref` kills it, for the rest of its think.
  defp kills?(state, id, entry, {:mob, uuid}, effects) do
    with target_id when target_id != nil <- state.by_uuid[uuid],
         target = state.entries[target_id],
         {:ok, hit} <-
           Valimc.Entity.Combat.mob_hit(
             %{entries: %{id => attacker(id, entry)}},
             id,
             target.body.type
           ),
         hit = Map.merge(hit, extras(effects, uuid)),
         {body, _, true} <- Valimc.Entity.Combat.hit_body(target.body, target.entity, hit) do
      not Valimc.Entity.Mob.alive?(body.mob)
    else
      _ -> false
    end
  end

  # The attacker as a store entry (`Combat.mob_hit/3`).
  defp attacker(id, entry),
    do: %{Map.put(entry, :kind, :mob) | entity: Map.put_new(entry.entity, :entity_id, id)}

  defp extras(effects, uuid) do
    Enum.find_value(effects, %{}, fn
      {:attack_extra, {:mob, ^uuid}, extras} -> extras
      _ -> nil
    end)
  end

  defp timers(%{mob: mob} = body) do
    health = Valimc.Living.Health.tick(mob.living.health)
    %{body | mob: %{mob | living: %{mob.living | health: health}}}
  end

  # A hurt mob's entry, and its step if it already ticked (with the hit's
  # entity events), as others sense it.
  defp hurt(state, ticker, id, entry, events) do
    sync_collider(ticker, state, state.index[id], entry)

    {steps, stepped} =
      Enum.map_reduce(state.steps, false, fn
        %{id: ^id} = step, _ -> {%{step | body: entry.body, events: step.events ++ events}, true}
        step, stepped -> {step, stepped}
      end)

    pending =
      if stepped, do: state.pending, else: Map.update(state.pending, id, events, &(&1 ++ events))

    %{
      state
      | entries: Map.put(state.entries, id, entry),
        steps: steps,
        pending: pending,
        world: AI.resense_entry(state.world, id, entry)
    }
  end

  # Entity.baseTick refreshes fluid observations before every AI turn. A
  # water move may retain its old flag until this refresh, including on exit.
  defp sense_fluids(view, %{body: %{mob: %Valimc.Entity.Mob{} = mob} = body} = entry) do
    {_, _, eye} = Valimc.Entity.Body.dimensions(body)
    e = entry.entity

    with {:ok, %{water: water, lava: lava}} <- Kernel.fluids(view, box(entry)),
         {:ok, eye} <- Kernel.eye_block(view, box(entry), {e.x * 1.0, e.y + eye, e.z * 1.0}) do
      motion = %{mob.motion | water: water * 1.0, lava: lava * 1.0, eye: eye}
      %{entry | body: %{body | mob: %{mob | motion: motion}}}
    else
      _ -> entry
    end
  end

  defp sense_fluids(_view, entry), do: entry

  defp box(%{entity: e, body: body}) do
    {width, height, _} = Valimc.Entity.Body.dimensions(body)
    half = width / 2.0
    {e.x - half, e.y * 1.0, e.z - half, e.x + half, e.y + height, e.z + half}
  end

  # Farmland the mob landed on gives way (VMC-039a, `FarmlandBlock.fallOn`);
  # the owner applies it while mob griefing is on.
  defp trample(body, %{landing: {state, distance}, landing_pos: cell}) when cell != nil do
    {w, h, _} = Valimc.Entity.Body.dimensions(body)
    roll = (:rand.uniform(16_777_216) - 1) / 16_777_216

    if Valimc.Blocks.Farmland.tramples?(state, distance, {w, h}, roll),
      do: [{:trample, cell}],
      else: []
  end

  defp trample(_body, _ticked), do: []

  @turtle_egg Valimc.Data.Blocks.id("turtle_egg")
  # `Zombie.class` and its kinds never crack eggs falling (`fallOn`).
  @zombies ~w(minecraft:zombie minecraft:husk minecraft:drowned minecraft:zombie_villager minecraft:zombified_piglin)

  # `TurtleEggBlock.fallOn` (one in three, not a zombie) and `stepOn` (one
  # in a hundred on the ground) for a mob that may break eggs (not a turtle
  # or bat, while mobs may grief), from the level's random: `{:crack_egg,
  # cell, state}` effects and their sounds, pitched from it too.
  defp eggs(%{type: type}, ticked, world)
       when type not in ["minecraft:turtle", "minecraft:bat"] do
    if world.mob_griefing do
      {fall, world} =
        case ticked do
          %{landing: {state, _}, landing_pos: cell} when cell != nil and type not in @zombies ->
            crack(world, cell, state, 3)

          _ ->
            {[], world}
        end

      {step, world} =
        case ticked do
          %{on_block: {cell, state}} -> crack(world, cell, state, 100)
          _ -> {[], world}
        end

      {fall ++ step, world}
    else
      {[], world}
    end
  end

  defp eggs(_body, _ticked, world), do: {[], world}

  defp crack(world, cell, state, chance) do
    if Valimc.Data.Blocks.block_id(state) == @turtle_egg do
      {n, random} = AI.Random.int(world.random, chance)

      if n == 0 do
        {f, random} = AI.Random.float(random)
        pitch = Float32.round(Float32.round(0.9) + Float32.round(f * Float32.round(0.2)))
        {cx, cy, cz} = cell
        id = AI.Facts.sound_id("minecraft:entity.turtle.egg_break")

        sound =
          {:sound_at, id, "blocks", {cx + 0.5, cy + 0.5, cz + 0.5}, Float32.round(0.7), pitch}

        {[{:crack_egg, cell, state}, sound], %{world | random: random}}
      else
        {[], %{world | random: random}}
      end
    else
      {[], world}
    end
  end

  # Sounds, entity events and swings are the mob's events; the rest leaves it.
  defp split(effects) do
    {events, rest} =
      Enum.split_with(effects, fn
        {:sound, _, _, _, _, _} -> true
        {:sound_at, _, _, _, _, _} -> true
        {:sound_block, _, _, _, _, _} -> true
        {:damage, _} -> true
        {:damage, _, _, _, _} -> true
        {:event, _} -> true
        {:particles, _, _, _, _, _} -> true
        :swing -> true
        {:swing, _} -> true
        _ -> false
      end)

    {Enum.map(events, fn
       :swing -> {:swing, :main_hand}
       e -> e
     end), rest}
  end
end
