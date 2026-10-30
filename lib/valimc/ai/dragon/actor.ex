defmodule Valimc.AI.Dragon.Actor do
  @moduledoc """
  The dragon's complete owner-local tick (VMC-045a5). Phase/flight state,
  crystal selection and the death clock live in its one body's data. The
  caller supplies authoritative crystal/target rows and arena/block reads;
  effects enter the owner's existing hurt, projectile and block paths.
  """
  alias Valimc.AI.{Look, Mind, Random, Self}
  alias Valimc.AI.Dragon.{Facts, Flight, Paths, Phases}
  alias Valimc.Data.{BlockFacts, Float32}
  alias Valimc.Entity.{Body, Mob}

  defstruct phases: %Phases{},
            tick: 0,
            ambient: 0,
            body_yaw: 0.0,
            stable_head: 0.0,
            stable_time: 0,
            wall: false,
            crystal: nil,
            flame: nil,
            graph: nil,
            world_tick: nil

  @doc "The actor's inputs from the group's authoritative rows and sequential AI senses."
  def environment(body, entity, world) do
    arena = world.dragon

    graph =
      case body.data.brain do
        %{graph: graph} when graph != nil -> graph
        _ -> Paths.graph(arena.height)
      end

    players =
      for p <- world.players,
          p.alive and p.mode not in [:creative, :spectator] and not p.invulnerable,
          do: %{id: p.id, position: {p.x, p.y, p.z}, height: p.height}

    targets =
      for sensed <- arena.targets ++ world.players,
          sensed.uuid != entity.uuid,
          not (sensed.kind == :player and sensed.mode in [:creative, :spectator]) do
        ref = {sensed.kind, sensed.uuid}
        target = Valimc.AI.World.entity(world, ref) || sensed
        half = target.width / 2.0

        %{
          ref: ref,
          position: {target.x, target.y, target.z},
          recent: Map.get(target, :recent_mob_hurt, false),
          box:
            Map.get(target, :box) ||
              {target.x - half, target.y, target.z - half, target.x + half,
               target.y + target.height, target.z + half}
        }
      end

    Map.merge(arena, %{
      graph: graph,
      time: world.time,
      players: players,
      targets: targets,
      read: world.read,
      solid: fn cell ->
        case world.read.(cell) do
          nil -> false
          block -> not BlockFacts.air?(block)
        end
      end,
      max_y: world.max_y,
      mob_griefing: world.mob_griefing,
      mob_drops: world.mob_drops,
      visible: fn p ->
        from =
          {entity.x, entity.y + Valimc.Data.EntityTypes.fetch(body.type).eye_height, entity.z}

        target = Enum.find(world.players, &(&1.id == p.id))
        to = {target.x, target.y + target.eye, target.z}
        Valimc.Physics.Clip.clip(from, to, :none, world.read, :collider).miss
      end
    })
  end

  @doc "The shared living hurt input for a dragon contact."
  def hit(entity, amount) do
    me = %{
      uuid: entity.uuid,
      entity_id: entity.entity_id,
      player: false,
      type: "minecraft:ender_dragon",
      mainhand: nil
    }

    %{
      source: Valimc.Living.DamageSource.new(:mob_attack),
      amount: amount,
      attacker: me,
      direct: me,
      position: position(entity)
    }
  end

  def recent?(%{mob: %{ai: %Mind{tick: tick, hurt_by: {_, at}}}}), do: at >= tick - 2
  def recent?(%{mob: %{ai: %Mind{tick: tick}}}), do: tick <= 2
  def recent?(_body), do: false

  @doc "A destroyed healing crystal's head hit and the holding phase's retaliation."
  def crystal_destroyed(body, entity, crystal, direct, player, env) do
    {actor, mind} = restore(body, entity)
    actor = %{actor | graph: actor.graph || env.graph}
    body = %{body | data: %{body.data | brain: actor}, mob: %{body.mob | ai: mind}}

    {body, events} =
      if actor.crystal == crystal do
        hit = %{
          source: Valimc.Living.DamageSource.new(:explosion),
          amount: 10.0,
          dragon_part: 0,
          attacker: player && player.attacker,
          direct: direct,
          position: direct.position
        }

        {body, events, _} = Valimc.Entity.Combat.hit_body(body, entity, hit)
        {body, events}
      else
        {body, []}
      end

    if body.data.phase == 0 and player != nil and player.eligible do
      actor = body.data.brain

      phases = %{
        actor.phases
        | random: body.mob.ai.random,
          flight: %{actor.phases.flight | position: position(entity)}
      }

      phases = Phases.strafe(phases, player, %{env | graph: actor.graph})

      body = %{
        body
        | data: %{body.data | phase: phases.phase, brain: %{actor | phases: phases}},
          mob: %{body.mob | ai: %{body.mob.ai | random: phases.random}}
      }

      {body, events}
    else
      {body, events}
    end
  end

  @transparent MapSet.new(
                 Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:dragon_transparent"]
               )
  @immune MapSet.new(Valimc.Protocol.Data.tags()["minecraft:block"]["minecraft:dragon_immune"])

  @doc "Rebuild the transient mind after an intra-tick section handoff, without ticking twice."
  def resume(body, entity) do
    {actor, mind} = restore(body, entity)

    mind = %{
      mind
      | tick: actor.tick,
        ambient: actor.ambient,
        body_yaw: actor.body_yaw,
        stable_head: actor.stable_head,
        stable_time: actor.stable_time
    }

    %{body | mob: %{body.mob | ai: mind}}
  end

  @doc "One tick after the store's living timers: `{body, position, events, effects}`."
  def tick(%Body{} = body, entity, env) do
    {actor, mind} = restore(body, entity)

    actor = %{
      actor
      | tick: actor.tick + 1,
        graph: actor.graph || env.graph,
        world_tick: Map.get(env, :time)
    }

    mind = %{mind | tick: actor.tick, ambient: actor.ambient}
    end_flame = actor.phases.phase != body.data.phase and actor.phases.flame_live
    phases = actor.phases |> Phases.set(body.data.phase)
    flight = %{phases.flight | position: position(entity), velocity: body.velocity, yaw: body.yaw}

    phases = %{
      phases
      | flight: flight,
        head_yaw: body.head_yaw,
        pitch: body.pitch,
        random: mind.random
    }

    actor = %{actor | phases: phases}

    {body, actor, events, effects} =
      if Mob.alive?(body.mob) do
        {actor, sounds} = ambient(actor, body)
        {body, actor} = heal(body, actor, env.crystal_bodies)
        env = %{env | graph: actor.graph} |> Map.put(:wall, actor.wall)
        old_parts = actor.phases.flight |> Flight.boxes() |> List.to_tuple()
        phases = Phases.tick(actor.phases, env, body.mob.no_ai)

        phases =
          if end_flame, do: %{phases | effects: [:end_flame | phases.effects]}, else: phases

        actor = %{actor | phases: phases}

        actor =
          if :scan_crystals in phases.effects,
            do: scan(actor, env.crystal_bodies, position(entity), body),
            else: actor

        body =
          Enum.reduce(phases.effects, body, fn
            {:health, value}, body -> put_in(body.mob.living.health.value, value)
            _, body -> body
          end)

        {actor, walls} =
          if body.mob.no_ai, do: {actor, []}, else: walls(actor, env)

        contacts =
          if not body.mob.no_ai and body.mob.living.health.hurt_ticks == 0,
            do: contacts(actor, old_parts, env.targets),
            else: []

        fire_events =
          if Map.get(body.data, :silent, false),
            do: [],
            else:
              for(
                {:fireball, _, _} <- phases.effects,
                do: {:level_event, block_position(entity), 1017, 0}
              )

        {phase_effects, actor} =
          Enum.map_reduce(phases.effects, actor, fn
            {:flame, at}, actor ->
              # The owner's fresh uuid where it gives one (the parity's).
              uuid = Map.get(env, :flame_uuid) || :crypto.strong_rand_bytes(16)
              {{:dragon_flame, uuid, at}, %{actor | flame: uuid}}

            :end_flame, actor ->
              {{:dragon_end_flame, actor.flame}, %{actor | flame: nil}}

            effect, actor ->
              {effect, actor}
          end)

        {body, actor, sounds, fire_events ++ contacts ++ walls ++ phase_effects}
      else
        death(body, actor, env)
      end

    flight = actor.phases.flight
    {x, _, z} = flight.position
    {xo, _, zo} = position(entity)

    mind = %{
      mind
      | random: actor.phases.random,
        ambient: actor.ambient,
        body_yaw:
          if(Mob.alive?(body.mob) and not body.mob.no_ai, do: flight.yaw, else: actor.body_yaw),
        stable_head: actor.stable_head,
        stable_time: actor.stable_time
    }

    self =
      Look.body(
        %Self{
          type: body.type,
          x: x,
          z: z,
          yaw: flight.yaw,
          head: body.head_yaw,
          mind: mind,
          facts: %{max_head_y_rot: Facts.max_head_y_rot()}
        },
        {xo, zo}
      )

    actor = %{
      actor
      | body_yaw: self.mind.body_yaw,
        stable_head: self.mind.stable_head,
        stable_time: self.mind.stable_time
    }

    phases = %{actor.phases | head_yaw: self.head}
    actor = %{actor | phases: phases}

    body = %{
      body
      | velocity: flight.velocity,
        yaw: flight.yaw,
        head_yaw: self.head,
        data: %{body.data | phase: phases.phase, brain: actor},
        mob: %{body.mob | ai: self.mind}
    }

    {body, flight.position, events, effects}
  end

  defp restore(body, entity) do
    actor =
      case body.data.brain do
        %__MODULE__{} = actor ->
          actor

        %Phases{} = phases ->
          %__MODULE__{phases: phases}

        _ ->
          %__MODULE__{phases: %Phases{flight: %Flight{position: position(entity), yaw: body.yaw}}}
      end

    mind =
      case body.mob.ai do
        %Mind{} = mind -> mind
        kept -> Valimc.AI.mind(body.type, entity.uuid, kept, body.data)
      end

    {actor, mind}
  end

  defp ambient(actor, body) do
    {n, random} = Random.int(actor.phases.random, 1000)

    {ambient, random, events} =
      if n < actor.ambient do
        {pitch, random} = Random.voice_pitch(random, 1.0)

        events =
          if Map.get(body.data, :silent, false),
            do: [],
            else: [
              {:sound, "minecraft:entity.ender_dragon.ambient", "hostile", 5.0, pitch, 0}
            ]

        {-Facts.ambient_interval(), random, events}
      else
        {actor.ambient + 1, random, []}
      end

    {%{actor | ambient: ambient, phases: %{actor.phases | random: random}}, events}
  end

  defp heal(body, %{crystal: nil} = actor, _crystals), do: {body, actor}

  defp heal(body, actor, crystals) do
    if Enum.any?(crystals, &(&1.uuid == actor.crystal)) do
      health = body.mob.living.health

      value =
        if rem(actor.tick, 10) == 0,
          do: min(health.maximum, f(health.value + 1.0)),
          else: health.value

      {put_in(body.mob.living.health.value, value), actor}
    else
      {body, %{actor | crystal: nil}}
    end
  end

  # Native selection uses the pre-move root box and crystal boxes.
  defp scan(actor, crystals, {x, y, z} = origin, body) do
    {width, height, _} = Body.dimensions(body)
    half = width / 2.0

    box =
      {x - half - 32.0, y - 32.0, z - half - 32.0, x + half + 32.0, y + height + 32.0,
       z + half + 32.0}

    crystal =
      crystals
      |> Enum.filter(&intersects?(box, &1.box))
      |> Enum.min_by(&distance(&1.position, origin), fn -> nil end)

    %{actor | crystal: crystal && crystal.uuid}
  end

  defp contacts(actor, old, targets) do
    boxes = actor.phases.flight |> Flight.boxes() |> List.to_tuple()
    {bx0, _, bz0, bx1, _, bz1} = elem(boxes, 2)
    {cx, cz} = {(bx0 + bx1) / 2, (bz0 + bz1) / 2}

    wings =
      for i <- [6, 7],
          target <- targets,
          intersects?(inflate(elem(boxes, i), {4.0, 2.0, 4.0}, {0.0, -2.0, 0.0}), target.box) do
        {x, _, z} = target.position
        {dx, dz} = {x - cx, z - cz}
        dd = max(dx * dx + dz * dz, 0.1)

        amount =
          if not Facts.phase(actor.phases.phase).sitting and not Map.get(target, :recent, false),
            do: 5.0,
            else: 0.0

        {:dragon_contact, target.ref, {dx / dd * 4.0, f(0.2), dz / dd * 4.0}, amount, true}
      end

    heads =
      for i <- [0, 1],
          target <- targets,
          intersects?(inflate(elem(old, i), {1.0, 1.0, 1.0}), target.box),
          do: {:dragon_contact, target.ref, {0.0, 0.0, 0.0}, 10.0, false}

    wings ++ heads
  end

  defp walls(actor, env) do
    boxes = actor.phases.flight |> Flight.boxes() |> List.to_tuple()

    {wall, _removed, random, effects} =
      Enum.reduce([0, 1, 2], {false, %{}, actor.phases.random, []}, fn i,
                                                                       {wall, removed, random,
                                                                        effects} ->
        {x0, y0, z0, x1, y1, z1} = elem(boxes, i)

        {x0, y0, z0, x1, y1, z1} =
          {floor(x0), floor(y0), floor(z0), floor(x1), floor(y1), floor(z1)}

        cells = for x <- x0..x1, y <- y0..y1, z <- z0..z1, do: {x, y, z}
        blocks = if env[:blocks], do: env.blocks.(cells), else: Enum.map(cells, env.read)

        {wall, removed, edits} =
          Enum.zip(cells, blocks)
          |> Enum.reduce({wall, removed, []}, fn {cell, block}, {wall, removed, edits} ->
            id = if block, do: Valimc.Data.Blocks.block_id(block)

            cond do
              Map.has_key?(removed, cell) or block == nil or BlockFacts.air?(block) or
                  MapSet.member?(@transparent, id) ->
                {wall, removed, edits}

              env.mob_griefing and not MapSet.member?(@immune, id) ->
                {wall, Map.put(removed, cell, block), [{:dragon_break, cell, block} | edits]}

              true ->
                {true, removed, edits}
            end
          end)

        if edits == [] do
          {wall, removed, random, effects}
        else
          {x, random} = Random.int(random, x1 - x0 + 1)
          {y, random} = Random.int(random, y1 - y0 + 1)
          {z, random} = Random.int(random, z1 - z0 + 1)

          {wall, removed, random,
           effects ++ Enum.reverse(edits) ++ [{:level_event, {x0 + x, y0 + y, z0 + z}, 2008, 0}]}
        end
      end)

    {%{actor | wall: wall, phases: %{actor.phases | random: random}}, effects}
  end

  defp death(body, actor, env) do
    time = body.data.death_time + 1

    {actor, emitter} =
      if time in 180..200, do: particle(actor, "minecraft:explosion_emitter"), else: {actor, []}

    total = if Map.get(env, :previous_kill, true), do: 500, else: 12_000

    xp =
      if env.mob_drops and time > 150 and rem(time, 5) == 0,
        do: [{:dragon_xp, floor(f(total * f(0.08))), actor.phases.flight.position}],
        else: []

    sound =
      if time == 1 and not Map.get(body.data, :silent, false),
        do: [{:global_event, 1028}],
        else: []

    flight = actor.phases.flight
    delta = {0.0, f(0.1), 0.0}
    parts = flight.parts |> Tuple.to_list() |> Enum.map(&add(&1, delta)) |> List.to_tuple()
    flight = %{flight | position: add(flight.position, delta), parts: parts}
    actor = %{actor | phases: %{actor.phases | flight: flight}}

    {actor, particles, done} =
      if time >= 200 do
        xp =
          if env.mob_drops,
            do: [{:dragon_xp, floor(f(total * f(0.2))), actor.phases.flight.position}],
            else: []

        {actor, [], xp ++ [:dragon_killed, :discard]}
      else
        {actor, particles} = particle(actor, "minecraft:explosion")
        {actor, particles, []}
      end

    {%{body | data: %{body.data | death_time: time}}, actor, emitter ++ particles,
     sound ++ xp ++ done}
  end

  defp particle(actor, name) do
    {x, random} = Random.float(actor.phases.random)
    {y, random} = Random.float(random)
    {z, random} = Random.float(random)
    offset = {f(f(x - 0.5) * 8.0), 2.0 + f(f(y - 0.5) * 4.0), f(f(z - 0.5) * 8.0)}
    at = add(actor.phases.flight.position, offset)

    {%{actor | phases: %{actor.phases | random: random}},
     [{:particles, name, at, {0.0, 0.0, 0.0}, 0.0, 1}]}
  end

  defp block_position(e), do: {floor(e.x), floor(e.y), floor(e.z)}
  defp position(e), do: {e.x * 1.0, e.y * 1.0, e.z * 1.0}

  defp inflate(box, delta, move \\ {0.0, 0.0, 0.0}) do
    {a, b, c, d, e, f} = box
    {x, y, z} = delta
    {mx, my, mz} = move
    {a - x + mx, b - y + my, c - z + mz, d + x + mx, e + y + my, f + z + mz}
  end

  defp intersects?({a, b, c, d, e, f}, {g, h, i, j, k, l}),
    do: a < j and d > g and b < k and e > h and c < l and f > i

  defp distance({x, y, z}, {a, b, c}),
    do: (x - a) * (x - a) + (y - b) * (y - b) + (z - c) * (z - c)

  defp add({x, y, z}, {a, b, c}), do: {x + a, y + b, z + c}
  defp f(value), do: Float32.round(value)
end
