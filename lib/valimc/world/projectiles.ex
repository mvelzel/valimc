defmodule Valimc.World.Projectiles do
  @moduledoc """
  What a region owner's projectiles do each tick (VMC-037o): one kernel call
  moves them all (`Physics.Kernel.projectiles/5`), then each step is planned
  here as vanilla's `onHit` overrides plan it:

  - **Arrows** (`AbstractArrow`): a stuck arrow counts down its 1200 ticks
    and falls when its block goes; an arrow that hits a block sticks with its
    hit sound; one that hits an entity deals `ceil(speed × damage)` (a
    critical one up to half again) through the hurt path and is gone, or,
    when the hit does not take, bounces back at a tenth of its speed.
  - **Thrown items**: a hit entity takes the throw (`thrown`, 3 for a blaze
    from a snowball, else 0), then a snowball breaks, an egg may hatch
    chickens (1 in 8, four 1 in 32 of those), an ender pearl teleports its
    owner to where it was, and a splash potion applies its effects within
    four blocks, scaled by distance.
  - **Fireballs**: a small fireball sets what it hits on fire (5 seconds, 5
    damage) or lights the block it hits; a large one hits for 6 and
    explodes (power 1, fire and block damage as `mobGriefing` allows); the
    dragon's leaves a dragon's breath cloud where it lands.
  - **Eyes of ender** drift toward their target for 80 ticks, then drop as
    an item (four times in five) or shatter.

  A plan is `{:keep, body, position, effects}`, `{:remove, effects}` or
  `{:hurt, target, hit, then}`: the owner applies the hit and calls `then`
  with whether it took, which gives a plan. Effects are `{:sound, name,
  source, position, volume, pitch}`, `{:event, id, event, position}` (an
  entity event shown before the projectile goes), `{:level_event, cell,
  type, data}`, `{:spawn, record}`, `{:explode, explosion}`, `{:fire, cell}`,
  `{:player, uuid, message}`, `{:splash, body, location}`, `{:cloud,
  record}` and `{:effects, target, actions, hit}` (a shulker bullet's
  Levitation on what it hurt).
  """
  alias Valimc.Data.{EntityTypes, Float32, Grid}
  alias Valimc.Entity.{Body, Projectile, ShulkerBullet, Store}
  alias Valimc.Living.DamageSource
  alias Valimc.Physics.Kernel
  alias Valimc.Protocol.ItemStack

  @arrow "minecraft:arrow"
  @eye "minecraft:eye_of_ender"
  @bullet "minecraft:shulker_bullet"
  # A bullet's Levitation: ten seconds (`MobEffectInstance(LEVITATION, 200)`).
  @levitation {:add, Valimc.Data.EffectTypes.id("levitation"), [{200, 0, false, true, true}]}
  # `AbstractArrow.tickDespawn` and `SHAKE_TIME`.
  @despawn 1200
  @shake 7

  @doc """
  One kernel tick of the projectile `bodies` (`[{id, entry}]`) against
  `targets` (`%{id, position, box}`): `[{id, entry, result}]`.
  """
  def step([], _targets, _border, _fast_lava), do: []

  def step(bodies, targets, border, fast_lava) do
    # A shulker's bullet steers toward its target, if it still finds it.
    bodies =
      Enum.map(bodies, fn
        {id, %{body: %Body{type: @bullet} = body} = entry} ->
          {id, %{entry | body: ShulkerBullet.prepare(body, bullet_target(body, targets))}}

        other ->
          other
      end)

    inputs =
      Enum.map(bodies, fn {_, %{entity: e, body: body}} ->
        Projectile.input(body, {e.x * 1.0, e.y * 1.0, e.z * 1.0}, {float(), float(), float()})
      end)

    targets =
      for %{id: id, position: {x, y, z}, box: box} <- targets,
          do:
            {id, {x * 1.0, y * 1.0, z * 1.0},
             box |> Tuple.to_list() |> Enum.map(&(&1 * 1.0)) |> List.to_tuple()}

    {:ok, results} =
      Kernel.projectiles(Valimc.World.View.new(), inputs, targets, border, fast_lava)

    for {{id, entry}, result} <- Enum.zip(bodies, results), do: {id, entry, result}
  end

  @doc "The target of shulker bullet `body` among `targets` (by uuid), or nil."
  def bullet_target(%Body{data: %{target: {_, uuid}}}, targets),
    do: Enum.find(targets, &(Map.get(&1, :uuid) == uuid))

  def bullet_target(_body, _targets), do: nil

  # A Java `nextFloat`: 24 uniform bits.
  defp float, do: (:rand.uniform(16_777_216) - 1) / 16_777_216

  @doc """
  The plan of one step. `targets` maps a target's network id to `%{ref,
  position, type, uuid}`; `context` holds `mob_griefing`, `difficulty`,
  the target list (`targets`) and a block reader (`read`).
  """
  def plan(%{entity: e, body: body}, result, targets, context) do
    old = {e.x, e.y, e.z}
    # The projectile itself, the direct entity of its hits.
    me = %{uuid: e.uuid, entity_id: e.entity_id, player: false, type: body.type, mainhand: nil}
    context = Map.put(context, :me, me)

    case result do
      {:ok, state, hit, {_water, lava}, loosened} ->
        {position, _, _, _, _, _} = state
        body = Projectile.advance(body, state, lava)
        {_, y, _} = position

        if y < Grid.min_y() - 64,
          do: {:remove, []},
          else: planned(body, old, position, hit, loosened, targets, context)

      # A fireball outside loaded chunks is gone (`hasChunkAt`); the others
      # wait where they are.
      _ ->
        if Projectile.fireball?(body.type), do: {:remove, []}, else: {:keep, body, old, []}
    end
  end

  ## Arrows

  defp planned(%Body{type: @arrow} = body, _old, position, hit, loosened, targets, context) do
    d = body.data

    cond do
      d.in_ground and hit == nil ->
        life = if loosened, do: 0, else: d.life + 1

        if life >= @despawn,
          do: {:remove, []},
          else: {:keep, %{body | data: %{d | life: life}}, position, []}

      match?({:block, _, _, _, _, true}, hit) ->
        {:keep, Projectile.impulse(body), position, []}

      match?({:block, _, _, _, _, _}, hit) ->
        sound = {:sound, d.sound, "neutral", position, 1.0, hit_pitch()}
        data = %{d | shake: @shake, crit: false, sound: "minecraft:entity.arrow.hit", life: 0}
        {:keep, Projectile.impulse(%{body | data: data}), position, [sound]}

      match?({:entities, [_ | _]}, hit) ->
        {:entities, [{id, at} | _]} = hit

        case targets[id] do
          nil -> {:keep, tail(body), at, []}
          target -> arrow_hit(body, at, target, context)
        end

      true ->
        {:keep, body, position, []}
    end
  end

  ## Thrown items

  defp planned(%Body{type: type} = body, old, position, hit, _loosened, targets, context)
       when type in ~w(minecraft:snowball minecraft:egg minecraft:ender_pearl minecraft:splash_potion) do
    case hit do
      nil ->
        {:keep, body, position, []}

      {:entity, id, at} when type != "minecraft:splash_potion" ->
        case targets[id] do
          nil ->
            thrown(body, old, at, context)

          target ->
            damage =
              if type == "minecraft:snowball" and target.type == "minecraft:blaze",
                do: 3.0,
                else: 0.0

            hit = projectile_hit(body, context.me, at, :thrown, damage)
            {:hurt, target, hit, fn _ -> thrown(body, old, at, context) end}
        end

      {:entity, _id, at} ->
        thrown(body, old, at, context)

      {:block, at, _, _, _, _} ->
        thrown(body, old, at, context)
    end
  end

  ## Shulker bullets

  # Peaceful takes it (`checkDespawn`); what it hits takes 4 and floats up,
  # a block stops it with a sound; otherwise it turns where it must.
  defp planned(%Body{type: @bullet} = body, _old, position, hit, _, targets, context) do
    cond do
      context[:difficulty] == :peaceful ->
        {:remove, []}

      true ->
        case hit do
          nil ->
            target = bullet_target(body, context[:targets] || [])
            {:keep, ShulkerBullet.turn(body, position, target, context.read), position, []}

          {:entity, id, at} ->
            case targets[id] do
              nil ->
                {:remove, []}

              target ->
                hit = projectile_hit(body, context.me, at, :mob_projectile, 4.0)

                {:hurt, target, hit,
                 fn
                   true -> {:remove, [{:effects, target, [@levitation], hit}]}
                   false -> {:remove, []}
                 end}
            end

          {:block, _, _, _, _, _} ->
            {:remove,
             [{:sound, "minecraft:entity.shulker_bullet.hit", "hostile", position, 1.0, 1.0}]}
        end
    end
  end

  ## Fireballs

  defp planned(
         %Body{type: "minecraft:small_fireball"} = body,
         _old,
         position,
         hit,
         _,
         targets,
         context
       ) do
    case hit do
      nil ->
        {:keep, body, position, []}

      {:entity, id, at} ->
        case targets[id] do
          nil ->
            {:remove, []}

          target ->
            hit =
              body
              |> projectile_hit(context.me, at, fireball_source(body), 5.0)
              |> Map.put(:ignite, 100)

            {:hurt, target, hit, fn _ -> {:remove, []} end}
        end

      {:block, _at, face, cell, _, _} ->
        lights = context.mob_griefing or not mob_owned?(body)
        {:remove, if(lights, do: [{:fire, relative(cell, face)}], else: [])}
    end
  end

  defp planned(%Body{type: "minecraft:fireball"} = body, _old, position, hit, _, targets, context) do
    explode = fn at ->
      {:remove,
       [
         {:explode,
          %{
            Valimc.World.Explosion.tnt(at)
            | radius: body.data.power * 1.0,
              interacts: context.mob_griefing,
              fire: context.mob_griefing
          }}
       ]}
    end

    case hit do
      nil ->
        {:keep, body, position, []}

      {:entity, id, at} ->
        case targets[id] do
          nil ->
            explode.(at)

          target ->
            hit = projectile_hit(body, context.me, at, fireball_source(body), 6.0)
            {:hurt, target, hit, fn _ -> explode.(at) end}
        end

      {:block, at, _, _, _, _} ->
        explode.(at)
    end
  end

  defp planned(
         %Body{type: "minecraft:dragon_fireball"} = body,
         _old,
         position,
         hit,
         _,
         targets,
         _
       ) do
    case hit do
      nil ->
        {:keep, body, position, []}

      # `DragonFireball.onHit` passes over its owner.
      {:entity, id, at} ->
        if owner?(body, targets[id]), do: {:keep, body, position, []}, else: breath(body, at)

      {:block, _, _, _, _, _} ->
        breath(body, position)
    end
  end

  ## Eyes of ender

  defp planned(%Body{type: @eye} = body, _old, {x, y, z} = position, _hit, _, _, _) do
    life = body.data.life + 1

    if life > 80 do
      sound = {:sound, "minecraft:entity.ender_eye.death", "neutral", position, 1.0, 1.0}

      gone =
        if body.data.survive,
          do: {:spawn, item_record(body.data.item, position)},
          else: {:level_event, {floor(x), floor(y), floor(z)}, 2003, 0}

      {:remove, [sound, gone]}
    else
      {:keep, %{body | data: %{body.data | life: life}}, position, []}
    end
  end

  ## Arrow hits

  # `AbstractArrow.onHitEntity` on one entity (an arrow does not pierce).
  defp arrow_hit(body, at, target, context) do
    d = body.data
    {vx, vy, vz} = body.velocity
    speed = Float32.round(:math.sqrt(vx * vx + vy * vy + vz * vz))
    damage = min(ceil(speed * d.damage), 2_147_483_647)

    damage =
      if d.crit,
        do: min(damage + :rand.uniform(div(damage, 2) + 2) - 1, 2_147_483_647),
        else: damage

    hit = projectile_hit(body, context.me, at, :arrow, damage * 1.0)
    hit = if Projectile.burning?(body), do: Map.put(hit, :ignite, 100), else: hit
    # `Arrow.doPostHurtEffects`: a tipped arrow's effect (VMC-043b).
    hit = if d.effects != [], do: Map.put(hit, :effect, hd(d.effects)), else: hit

    {:hurt, target, hit,
     fn
       true ->
         sound = {:sound, d.sound, "neutral", at, 1.0, hit_pitch()}

         # The shooter hears a hit on another player.
         bell =
           case {target, d.owner} do
             {%{ref: {:player, uuid}}, %{player: true, uuid: owner}} when owner != uuid ->
               [{:player, owner, :arrow_hit_player}]

             _ ->
               []
           end

         {:remove, [sound | bell]}

       false ->
         # `ProjectileDeflection.REVERSE` at a fifth of the power, then the
         # tick's drag and gravity.
         {x, y, z} = body.velocity
         turn = Float32.round(170.0 + float() * 20.0)

         body = %{
           body
           | velocity: {x * -0.1, y * -0.1, z * -0.1},
             yaw: Float32.round(body.yaw + turn)
         }

         {bx, by, bz} = body.velocity

         if bx * bx + by * by + bz * bz < 1.0e-7 do
           drop = if d.pickup == :allowed, do: [{:spawn, item_record(d.item, at, 0.1)}], else: []
           {:remove, drop}
         else
           {:keep, Projectile.impulse(tail(body)), at, []}
         end
     end}
  end

  # The rest of an arrow's tick after its entity hit: drag (none in water)
  # and gravity.
  defp tail(%Body{velocity: {x, y, z}, data: d} = body) do
    drag = if d.in_water, do: 1.0, else: Float32.round(0.99)
    gravity = if body.no_gravity or d.in_ground, do: 0.0, else: 0.05
    %{body | velocity: {x * drag, y * drag - gravity, z * drag}}
  end

  # `1.2 / (random.nextFloat() * 0.2 + 0.9)`.
  defp hit_pitch, do: Float32.round(1.2 / Float32.round(Float32.round(float() * 0.2) + 0.9))

  ## Thrown hits

  defp thrown(%Body{type: "minecraft:snowball"}, _old, at, _context),
    do: {:remove, [{:event, 3, at}]}

  defp thrown(%Body{type: "minecraft:egg"} = body, _old, at, _context) do
    count =
      cond do
        :rand.uniform(8) != 1 -> 0
        :rand.uniform(32) == 1 -> 4
        true -> 1
      end

    chicks = for _ <- 1..count//1, do: {:spawn, chick(body, at)}
    {:remove, [{:event, 3, at} | chicks]}
  end

  defp thrown(%Body{type: "minecraft:ender_pearl"} = body, old, _at, _context) do
    case body.data.owner do
      %{player: true, uuid: uuid} -> {:remove, [{:player, uuid, {:ender_pearl, old}}]}
      _ -> {:remove, []}
    end
  end

  defp thrown(%Body{type: "minecraft:splash_potion"} = body, _old, at, _context),
    do: {:remove, [{:splash, body, at}]}

  # `ThrownEgg.onHit`: a chick (age -24000) at the egg, facing its way.
  defp chick(body, {x, y, z}) do
    {:ok, chicken} = Body.new("minecraft:chicken")
    chicken = %{chicken | yaw: body.yaw, head_yaw: body.yaw, data: %{chicken.data | age: -24_000}}
    Store.body_record(chicken, :crypto.strong_rand_bytes(16), {x, y, z})
  end

  ## Fireball hits

  # `damageSources().fireball(this, owner)`: unattributed without an owner.
  defp fireball_source(%Body{data: %{owner: nil}}), do: :unattributed_fireball
  defp fireball_source(_body), do: :fireball

  defp owner?(%Body{data: %{owner: %{uuid: uuid}}}, %{uuid: uuid}), do: true
  defp owner?(_body, _target), do: false

  # `BlockPos.relative(direction)`, in `Direction` order.
  defp relative({x, y, z}, face) do
    {dx, dy, dz} =
      elem({{0, -1, 0}, {0, 1, 0}, {0, 0, -1}, {0, 0, 1}, {-1, 0, 0}, {1, 0, 0}}, face)

    {x + dx, y + dy, z + dz}
  end

  defp mob_owned?(%Body{data: %{owner: %{player: false}}}), do: true
  defp mob_owned?(_body), do: false

  # `DragonFireball.onHit`: a dragon's breath cloud and level event 2006.
  defp breath(body, {x, y, z} = at) do
    cloud = Valimc.Entity.EffectCloud.dragon_breath(body.data.owner)
    record = Store.body_record(cloud, :crypto.strong_rand_bytes(16), at)
    {:remove, [{:cloud, record}, {:level_event, {floor(x), floor(y), floor(z)}, 2006, 1}]}
  end

  ## Hits

  @doc """
  The hit of `body` (the direct entity `me`) at `at` dealing `amount` of damage type `type`: the
  projectile is the direct entity, its owner (or itself) the attacker, and
  knockback follows its motion (`calculateHorizontalHurtKnockbackDirection`).
  """
  def projectile_hit(%Body{} = body, me, at, type, amount) do
    {vx, _, vz} = body.velocity

    attacker =
      case body.data.owner do
        nil ->
          me

        owner ->
          %{
            uuid: owner.uuid,
            entity_id: owner.id,
            player: owner.player,
            type: owner[:type],
            mainhand: nil
          }
      end

    %{
      source: DamageSource.new(type),
      amount: amount,
      attacker: attacker,
      direct: me,
      position: at,
      direction: {-vx, -vz},
      projectile: true
    }
  end

  @doc "`ItemEntity` of `stack` at `position` (`spawnAtLocation`, `offset` up)."
  def item_record(%ItemStack{} = stack, {x, y, z}, offset \\ 0.0) do
    [vx, vz] = for _ <- 1..2, do: :rand.uniform_real() * 0.2 - 0.1

    %{
      uuid: :crypto.strong_rand_bytes(16),
      x: x,
      y: y + offset,
      z: z,
      stack: stack,
      motion: %Valimc.Entity.ItemMotionState{velocity: {vx, 0.2, vz}, pickup_delay: 10}
    }
  end

  @doc """
  `AbstractThrownPotion.onHit`'s splash: for each living target near
  `location` (`%{ref, box, type}`), the effects it receives: `{target,
  actions}` with actions `{:add, id, [rung]}`, `{:heal, amount}` or
  `{:hurt, :indirect_magic, amount}` scaled by distance, and the level
  events of the splash.
  """
  def splash(%Body{} = body, {lx, ly, lz} = location, targets, age) do
    stack = Projectile.stack(body)
    contents = potion_contents(stack)
    effects = Valimc.Protocol.PotionContents.effects(contents)
    %{width: w, height: h} = EntityTypes.fetch(body.type)
    half = w / 2
    potion = {lx - half, ly, lz - half, lx + half, ly + h, lz + half}
    margin = ((age - 2) / 20) |> max(0.0) |> min(0.3)

    hits =
      for target <- targets,
          dist = box_distance_sq(potion, inflate(target.box, margin)),
          box_intersects?(target.box, inflate3(potion, 4.0, 2.0, 4.0)),
          dist < 16.0 do
        scale = 1.0 - :math.sqrt(dist) / 4.0
        {target, Enum.flat_map(effects, &splash_effect(&1, scale, target.type))}
      end

    instant = Enum.any?(effects, fn {id, _} -> id in instant_ids() end)
    color = potion_color(contents, effects)
    {x, y, z} = location
    cell = {floor(x), floor(y), floor(z)}
    events = [{:level_event, cell, if(instant, do: 2007, else: 2002), color}]
    {Enum.reject(hits, fn {_, actions} -> actions == [] end), events}
  end

  defp instant_ids,
    do: Enum.map(~w(instant_health instant_damage), &Valimc.Data.EffectTypes.id/1)

  defp splash_effect({id, [{ticks, amp, ambient, particles, icon} | _]}, scale, type) do
    heal = Valimc.Data.EffectTypes.id("instant_health")
    harm = Valimc.Data.EffectTypes.id("instant_damage")
    inverted = type != "minecraft:player" and EntityTypes.tag?(type, "inverted_healing_and_harm")

    cond do
      id in [heal, harm] ->
        heals = id == heal != inverted

        if heals,
          do: [{:heal, trunc(scale * Bitwise.bsl(4, amp) + 0.5) * 1.0}],
          else: [{:hurt, :indirect_magic, trunc(scale * Bitwise.bsl(6, amp) + 0.5) * 1.0}]

      true ->
        duration = trunc(scale * ticks + 0.5)
        # `endsWithin(20)` drops the shortest.
        if duration >= 20 or ticks == -1,
          do: [
            {:add, id, [{if(ticks == -1, do: -1, else: duration), amp, ambient, particles, icon}]}
          ],
          else: []
    end
  end

  defp potion_contents(%ItemStack{} = stack) do
    case Map.fetch(stack.components, "minecraft:potion_contents") do
      {:ok, value} ->
        value

      :error ->
        case Valimc.Protocol.ItemTypes.defaults(stack.item_id).values["minecraft:potion_contents"] do
          nil ->
            Valimc.Protocol.PotionContents.empty()

          bytes ->
            {value, <<>>} = Valimc.Protocol.PotionContents.take(bytes)
            value
        end
    end
  end

  # `PotionContents.getColor`: the custom color, else a water potion's blue.
  defp potion_color(%{color: color}, _effects) when is_integer(color), do: color
  defp potion_color(_contents, _effects), do: -13_083_194

  defp box_distance_sq({ax0, ay0, az0, ax1, ay1, az1}, {bx0, by0, bz0, bx1, by1, bz1}) do
    dx = max(max(ax0 - bx1, bx0 - ax1), 0.0)
    dy = max(max(ay0 - by1, by0 - ay1), 0.0)
    dz = max(max(az0 - bz1, bz0 - az1), 0.0)
    dx * dx + dy * dy + dz * dz
  end

  defp inflate(box, d), do: inflate3(box, d, d, d)

  defp inflate3({x0, y0, z0, x1, y1, z1}, dx, dy, dz),
    do: {x0 - dx, y0 - dy, z0 - dz, x1 + dx, y1 + dy, z1 + dz}

  defp box_intersects?({ax0, ay0, az0, ax1, ay1, az1}, {bx0, by0, bz0, bx1, by1, bz1}),
    do: ax0 < bx1 and ax1 > bx0 and ay0 < by1 and ay1 > by0 and az0 < bz1 and az1 > bz0
end
