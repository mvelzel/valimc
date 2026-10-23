# Vanilla mobs ticking with their own goals and brains (MobAiOracle cases)
# against the owner's mob tick (VMC-041a): each scene's blocks as a supplied
# view, the same players standing still, the same items lying, the same
# hits between ticks, the mobs' (and their brains' and the level's) randoms
# seeded alike, and vanilla's path search over the same view (VMC-041b).
# Every tick, each mob's position, rotations (yaw, head, body, pitch),
# random seed, running goals and target goals, target, arms raised, path,
# hits on players and sounds must equal vanilla's; a brain's running
# behaviours, activity, off hand, admire time, the level random and items
# taken too; level events and the entities a mob adds (fireballs) too.
# An optional second argument is the least number of scenes (another
# family's oracle, VMC-043d's NetherMobOracle, has fewer).
alias Valimc.AI
alias Valimc.Entity.{Body, Combat, MobTicks}
alias Valimc.Living.DamageSource

{path, least} =
  case System.argv() do
    [path] -> {path, 9}
    [path, least] -> {path, String.to_integer(least)}
  end

Valimc.Data.BlockFacts.install!()
{fixtures, :ok, ""} = :json.decode(File.read!(path), :ok, %{null: nil})
cases = fixtures["cases"]
unless length(cases) >= least, do: raise("Incomplete mob AI traces")

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

vector = fn [x, y, z] -> {double.(x), double.(y), double.(z)} end

float = fn bits ->
  <<v::float-32>> = <<bits::signed-32>>
  v * 1.0
end

bits = fn v ->
  <<b::signed-32>> = <<v::float-32>>
  b
end

hex = fn v -> Base.encode16(<<v::float-64>>, case: :lower) end

air = Valimc.Data.Blocks.default_state("air")

# Sound ids the AI plays by name, and the farm animals' by their sound
# variants (VMC-043c).
sound_names =
  for file <- ~w(ai_facts animal_facts),
      {n, id} <- :json.decode(File.read!("priv/registry/#{file}.json"))["sounds"],
      into: %{},
      do: {id, n}

# A scene as a supplied view: its blocks, and air around them.
view = fn blocks, flier ->
  scene = Map.new(blocks, fn [x, y, z, s] -> {{x, y, z}, s} end)
  {xs, zs} = {Enum.map(blocks, &Enum.at(&1, 0)), Enum.map(blocks, &Enum.at(&1, 2))}
  {x0, x1} = {min(-16, Enum.min(xs) - 4), max(16, Enum.max(xs) + 4)}
  {z0, z1} = {min(-16, Enum.min(zs) - 4), max(16, Enum.max(zs) + 4)}
  ys = Enum.map(blocks, &Enum.at(&1, 1))
  {y0, y1} = {min(56, Enum.min(ys) - 4), max(80, Enum.max(ys) + 8)}
  # Wide enough for a flier's drift (a ghast's, VMC-043d).
  {x0, x1, z0, z1} = if flier, do: {x0 - 24, x1 + 24, z0 - 24, z1 + 24}, else: {x0, x1, z0, z1}
  {y0, y1} = if flier, do: {min(y0, 40), max(y1, 104)}, else: {y0, y1}

  packed =
    for x <- x0..x1, y <- y0..y1, z <- z0..z1, into: <<>> do
      <<x::signed-32, y::signed-32, z::signed-32, Map.get(scene, {x, y, z}, air)::16>>
    end

  {scene, {:states, packed}}
end

player = fn p ->
  {x, y, z} = vector.(p["position"])
  mode = String.to_atom(p["mode"])

  %{
    kind: :player,
    uuid: <<1::64, p["uuid"]::64>>,
    id: p["id"],
    x: x,
    y: y,
    z: z,
    yaw: if(p["yaw"], do: float.(p["yaw"]), else: 0.0),
    pitch: if(p["pitch"], do: float.(p["pitch"]), else: 0.0),
    eye: Valimc.Data.Float32.round(1.62),
    width: Valimc.Data.Float32.round(0.6),
    height: Valimc.Data.Float32.round(1.8),
    mode: mode,
    invulnerable: mode == :creative,
    alive: true,
    crouching: false,
    swimming: p["swimming"] == true,
    invisible: false,
    armor_cover: 0.0,
    equipment: %{
      mainhand: p["mainhand"] && Valimc.Protocol.ItemTypes.id(p["mainhand"]),
      offhand: nil,
      head: p["head"] && Valimc.Protocol.ItemTypes.id(p["head"])
    }
  }
end

goal_names = fn body, which ->
  {goals, targets} = Valimc.AI.Mobs.registered(body.type)
  registered = if which == :goals, do: goals, else: targets
  entries = Tuple.to_list(if which == :goals, do: body.mob.ai.goals, else: body.mob.ai.targets)

  # A goal that stands for another as the mob's weapon changes names it
  # (`vanilla_name`, a skeleton's, VMC-043b3).
  for {%{running: true} = entry, {_, name, _, _, _}} <- Enum.zip(entries, registered),
      do: (is_map(entry.state) && Map.get(entry.state, :vanilla_name)) || name
end

# A brain as the oracle seeded it: its RunOnes' randoms and sensors' countdowns.
brain = fn
  nil, _, _ ->
    nil

  brain, gates, times ->
    {behaviors, _} =
      brain.behaviors
      |> Tuple.to_list()
      |> Enum.map_reduce(gates, fn
        %{kind: Valimc.AI.Behavior.Gate} = b, [seed | rest] ->
          {%{b | random: AI.Random.new(seed)}, rest}

        b, gates ->
          {b, gates}
      end)

    sensors = Enum.zip_with(brain.sensors, times, fn s, t -> %{s | time: t} end)
    %{brain | behaviors: List.to_tuple(behaviors), sensors: sensors}
end

offhand = fn
  nil -> nil
  stack -> stack.item_id
end

admiring = fn mind ->
  case mind.brain.memories do
    %{admiring_item: {_, ttl}} -> ttl
    _ -> -1
  end
end

# An entity a mob added, as the oracle records it: a projectile with its
# rotation, a thrown item with its stack.
zero = Enum.map([0.0, 0.0, 0.0], hex)

added = fn
  {:projectile, type, at, velocity, {yaw, pitch}} ->
    [
      type,
      Enum.map(Tuple.to_list(at), hex),
      Enum.map(Tuple.to_list(velocity), hex),
      bits.(yaw),
      bits.(pitch)
    ]

  {:throw, stack, at, velocity} ->
    [
      "minecraft:item",
      Enum.map(Tuple.to_list(at), hex),
      Enum.map(Tuple.to_list(velocity), hex),
      Valimc.Protocol.ItemTypes.item(stack.item_id)["name"],
      stack.count
    ]

  # A shulker's bullet (at its box's centre, still) or offspring (VMC-043e).
  {:shoot_bullet, at, _, _} ->
    ["minecraft:shulker_bullet", Enum.map(Tuple.to_list(at), hex), zero, 0, 0]

  {:spawn_mob, type, at, _} ->
    [type, Enum.map(Tuple.to_list(at), hex), zero, 0, 0]

  _ ->
    nil
end

sound_name = fn
  id when is_integer(id) -> sound_names[id]
  name -> name
end

# The sounds a mob made: at itself, or where it was (a shulker's teleport).
sound_of = fn
  {:sound, name, _, volume, pitch, _} -> [{name, volume, pitch}]
  {:sound_at, name, _, _, volume, pitch} -> [{name, volume, pitch}]
  _ -> []
end

# A mob as the oracle set it up (VMC-043d): a weapon in hand, a baby (with
# its speed modifier, as `setBaby` adds it).
setup = fn body, m ->
  body =
    case m["mainhand"] do
      nil ->
        body

      item ->
        stack = Valimc.Protocol.ItemStack.new(item)
        %{body | mob: %{body.mob | equipment: Map.put(body.mob.equipment, :mainhand, stack)}}
    end

  body =
    case m["size"] do
      nil ->
        body

      size ->
        cube =
          if body.type == "minecraft:slime",
            do: Valimc.AI.Mobs.Slime,
            else: Valimc.AI.Mobs.MagmaCube

        {mob, data} = cube.set_size(body.mob, body.data, size)
        %{body | mob: mob, data: data}
    end

  if m["baby"] do
    speed = %{base: nil, modifiers: [{"minecraft:baby", Valimc.Data.Float32.round(0.2), 1}]}
    attributes = Map.put(body.mob.attributes, "minecraft:movement_speed", speed)
    %{body | data: %{body.data | baby: true}, mob: %{body.mob | attributes: attributes}}
  else
    body
  end
end

# What a family's mob keeps of its own (VMC-043e), as the oracle reports it.
kind_data = fn
  %{type: "minecraft:shulker", data: data, mob: mob} ->
    %{
      "attach_face" => data.attach_face,
      "peek" => data.peek,
      "peek_amount" => bits.(data.peek_amount),
      "armor" => hex.(Valimc.Entity.Mob.value("minecraft:shulker", mob, "minecraft:armor"))
    }

  %{type: "minecraft:endermite", data: data} ->
    %{"life" => data.life}

  %{type: type, data: data, mob: mob} when type in ~w(minecraft:magma_cube minecraft:slime) ->
    %{
      "size" => data.size,
      "was_on_ground" => data.was_on_ground,
      "jump_delay" => Valimc.AI.Mobs.Cube.own(mob.ai).jump_delay
    }

  %{type: type, data: data, mob: mob} = body
  when type in ~w(minecraft:cod minecraft:salmon minecraft:tropical_fish minecraft:pufferfish) ->
    fish = %{
      "from_bucket" => data.from_bucket,
      "move_dist" => bits.(mob.motion.move_dist),
      "next_step" => bits.(mob.motion.next_step)
    }

    fish =
      if type in Valimc.AI.Mobs.Fish.schooling() do
        school = Valimc.AI.Mobs.Fish.school(mob.ai)

        Map.merge(fish, %{
          "leader" =>
            if(school.leader,
              do: :binary.decode_unsigned(binary_part(school.leader, 0, 8)),
              else: -1
            ),
          "school" => school.school
        })
      else
        fish
      end

    case type do
      "minecraft:salmon" ->
        Map.put(fish, "size", data.size)

      "minecraft:tropical_fish" ->
        Map.put(fish, "variant", data.variant)

      "minecraft:pufferfish" ->
        c = Valimc.AI.Mobs.Pufferfish.counters(mob.ai)
        Map.merge(fish, %{"puff" => data.puff, "inflate" => c.inflate, "deflate" => c.deflate})

      _ ->
        _ = body
        fish
    end

  %{type: type, data: data, mob: mob} when type in ~w(minecraft:squid minecraft:glow_squid) ->
    o = Valimc.AI.Mobs.Squid.own(mob.ai)

    squid = %{
      "tentacle" => bits.(o.tentacle),
      "tentacle_speed" => bits.(o.tentacle_speed),
      "rotate_speed" => bits.(o.rotate_speed),
      "x_rot" => bits.(o.x_rot),
      "z_rot" => bits.(o.z_rot),
      "movement" => Enum.map(Tuple.to_list(o.movement), hex),
      "age" => data.age
    }

    if type == "minecraft:glow_squid", do: Map.put(squid, "dark", data.dark), else: squid

  %{type: "minecraft:dolphin", data: data, mob: mob} ->
    held = mob.equipment[:mainhand]

    %{
      "got_fish" => data.got_fish,
      "moistness" => data.moistness,
      "air" => mob.living.air_supply,
      "mainhand" => held && Valimc.Protocol.ItemTypes.item(held.item_id)["name"]
    }

  %{type: "minecraft:bat", data: data, mob: mob} ->
    case mob.ai.own do
      {x, y, z} -> %{"resting" => data.resting, "target" => [x, y, z]}
      nil -> %{"resting" => data.resting}
    end

  %{type: type, data: data, mob: mob}
  when type in ~w(minecraft:guardian minecraft:elder_guardian) ->
    guardian = %{"moving" => data.moving, "beam" => data.beam}

    case mob.home do
      {{x, y, z}, r} -> Map.put(guardian, "home", [x, y, z, r])
      nil -> guardian
    end

  _ ->
    %{}
end

# How a family's scene prepares a mob (VMC-043b): equipment, a baby, loot
# pickup, fire.
prepare = fn
  body, nil ->
    body

  body, p ->
    equipment =
      Map.new(p["equipment"], fn {slot, item} ->
        {String.to_existing_atom(slot), Valimc.Protocol.ItemStack.new(item)}
      end)

    mob = %{body.mob | equipment: Map.merge(body.mob.equipment, equipment)}
    mob = %{mob | can_pick_up_loot: p["loot"], living: %{mob.living | fire_ticks: p["fire"]}}
    body = %{body | mob: mob}

    # A lit or charged creeper (VMC-043b4).
    body =
      Enum.reduce(p["flags"] || [], body, fn
        "ignited", b ->
          %{b | data: %{b.data | ignited: true}}

        "powered", b ->
          %{b | data: %{b.data | powered: true}}

        # An enderman carrying a block.
        "carry=" <> name, b ->
          %{b | data: %{b.data | carried: Valimc.Data.Blocks.default_state(name)}}
      end)

    if p["baby"] do
      self = %Valimc.AI.Self{type: body.type, mob: body.mob, mind: body.mob.ai, data: body.data}
      self = Valimc.AI.Mobs.Zombie.set_baby(self, true)
      %{body | mob: self.mob, data: self.data}
    else
      body
    end
end

# A family's extra fields of a mob's tick: fire, health, equipment (item,
# wear, drop chance), its type and whether it converts or was removed.
extras = fn body, step ->
  equipment =
    for {slot, stack} <- body.mob.equipment, into: %{} do
      {Atom.to_string(slot),
       [
         Valimc.Protocol.ItemTypes.item(stack.item_id)["name"],
         Map.get(stack.components, "minecraft:damage", 0),
         bits.(Valimc.Entity.Mob.drop_chance(body.mob, slot))
       ]}
    end

  %{
    "type" => body.type,
    "removed" => Enum.any?(step.effects, &(match?({:convert, _}, &1) or &1 == :discard)),
    "fire" => body.mob.living.fire_ticks,
    "health" => bits.(body.mob.living.health.value),
    "equipment" => equipment,
    "can_pick_up_loot" => body.mob.can_pick_up_loot,
    "converting" => Map.get(body.data, :converting)
  }
  |> Map.merge(
    case body.data do
      # A creeper's fuse (VMC-043b4).
      %{swell_dir: dir, swell: swell} ->
        %{"swell_dir" => dir, "swell" => swell}

      # A spider's climbing.
      %{climbing: climbing} ->
        %{"climbing" => climbing}

      # An enderman's block and flags (VMC-043b5).
      %{drinking: drinking} ->
        %{"drinking" => drinking}

      %{carried: carried, creepy: creepy, stared_at: stared} ->
        %{"carried" => carried, "creepy" => creepy, "stared_at" => stared}

      _ ->
        %{}
    end
  )
end

# The hit a mob's effect lands on a player, with what it adds (VMC-043b:
# fire, an effect): a melee hit, a guardian's beam or thorns (a pufferfish's
# sting on a player stands for the player's own touch, which the oracle's
# players do not run).
hit_of = fn
  {:attack, {:player, <<_::64, n::64>> = uuid}}, effects ->
    extras =
      Enum.find_value(effects, %{}, fn
        {:attack_extra, {:player, ^uuid}, extras} -> extras
        _ -> nil
      end)

    case extras do
      %{effect: {effect, {duration, _, _, _, _}}} ->
        {n, Valimc.Data.EffectTypes.name(effect), duration, extras[:ignite]}

      _ ->
        {n, nil, nil, extras[:ignite]}
    end

  {:hurt, {:player, <<_::64, n::64>>}, type, _, _}, _effects when type != :mob_attack ->
    {n, nil, nil, nil}

  # A cube a player touches (VMC-043d: the oracle's players touch cubes).
  {:touch, {:player, <<_::64, n::64>>}, _, _}, _effects ->
    {n, nil, nil, nil}

  # A dolphin's grace.
  {:effect, {:player, <<_::64, n::64>>}, [{:add, id, [{duration, _, _, _, _}]}]}, _effects ->
    {n, Valimc.Data.EffectTypes.name(id), duration, nil}

  _, _ ->
    nil
end

# What a scene set on a family's mob as it was made (VMC-043e: a dolphin's
# air and moistness).
start_data = fn
  %{type: "minecraft:dolphin", mob: mob, data: data} = body, start ->
    mob = %{mob | living: %{mob.living | air_supply: start["air"]}}
    %{body | mob: mob, data: %{data | moistness: start["moistness"]}}

  body, _start ->
    body
end

# A squid's tentacle speed, drawn as vanilla made it (VMC-043e).
own_start = fn
  type, start when type in ~w(minecraft:squid minecraft:glow_squid) ->
    Map.merge(Valimc.AI.Mobs.Squid.own(nil), %{tentacle_speed: float.(start["tentacle_speed"])})

  _, _ ->
    nil
end

checked =
  for c <- cases, reduce: 0 do
    count ->
      {scene, kernel_view} =
        view.(
          c["blocks"],
          Enum.any?(c["mobs"], &(&1["type"] in ~w(minecraft:ghast minecraft:phantom)))
        )

      players = Enum.map(c["players"], player)

      items =
        for {item, n} <- Enum.with_index(c["items"]) do
          {x, y, z} = vector.(item["position"])

          %{
            kind: :item,
            uuid: <<n + 1::128>>,
            x: x,
            y: y,
            z: z,
            width: 0.25,
            height: 0.25,
            eye: Valimc.Data.Float32.round(0.2125),
            item: Valimc.Protocol.ItemTypes.id(item["item"]),
            count: item["count"],
            components: %{},
            pickup_delay: 0,
            alive: true
          }
        end

      # Blocks the mobs took or put down (an enderman's, VMC-043b5) read as
      # changed from then on; the kernel's view stays the scene's.
      for {{:mob_ai_edit, _} = key, _} <- Process.get(), do: Process.delete(key)

      world = %AI.World{
        read: fn cell -> Process.get({:mob_ai_edit, cell}) || Map.get(scene, cell, air) end,
        # Block searches (a piglin's repellents) over the scene's blocks.
        find: fn {x0, y0, z0, x1, y1, z1}, states ->
          for {{x, y, z} = position, state} <- scene,
              x in x0..x1 and y in y0..y1 and z in z0..z1,
              MapSet.member?(states, state),
              do: {position, state}
        end,
        # Vanilla's search answers at once (VMC-041b), over the same view.
        search: fn request ->
          [result] = AI.Paths.find(kernel_view, [request])
          result
        end,
        players: players,
        items: items,
        random: AI.Random.new(7),
        difficulty: :normal
      }

      # A family's lit scene (VMC-043b, HostileOracle): full sky light above
      # each column's top block, never darkened; by day monsters burn. Hits
      # read the probe's local difficulty.
      world =
        case c["day"] do
          nil ->
            world

          day ->
            tops =
              Enum.reduce(c["blocks"], %{}, fn [x, y, z, _], acc ->
                Map.update(acc, {x, z}, y, &max(&1, y))
              end)

            %{
              world
              | light: fn {x, y, z} ->
                  {if(y > Map.get(tops, {x, z}, -65), do: 15, else: 0), 0}
                end,
                monsters_burn: day,
                bright: day,
                local: Valimc.Living.LocalDifficulty.new(:normal, 0, 0, 0.0)
            }
        end

      entries =
        for {m, i} <- Enum.with_index(c["mobs"]) do
          yaw = float.(m["yaw"])
          {:ok, body} = Body.new(m["type"])
          {x, y, z} = vector.(m["position"])
          uuid = <<m["id"]::64, 0::64>>
          mind = AI.mind(m["type"], uuid, %{random: AI.Random.new(m["seed"])})
          # Seeded after it was made, as the oracle seeds it (a brain's sensor
          # countdowns drew on the random before).
          mind = %{
            mind
            | random: AI.Random.new(m["seed"]),
              body_yaw: yaw,
              brain: brain.(mind.brain, Enum.at(c["gates"], i), Enum.at(c["sensors"], i))
          }

          mind = %{mind | own: own_start.(m["type"], m["start"])}

          # A cube's move control faces its spawn yaw, as the oracle sets it (VMC-043d).
          mind =
            if m["type"] in ~w(minecraft:magma_cube minecraft:slime),
              do: %{mind | own: %{AI.Mobs.Cube.own(mind) | y_rot: yaw}},
              else: mind

          home =
            case m["start"]["home"] do
              [hx, hy, hz, r] -> {{hx, hy, hz}, r}
              nil -> nil
            end

          body = %{body | yaw: yaw, head_yaw: yaw, mob: %{body.mob | ai: mind, home: home}}
          body = start_data.(body, m["start"])
          body = prepare.(body, Enum.find(c["prepare"] || [], &(&1["index"] == i)))
          body = setup.(body, m)
          {m["id"], %{entity: %{uuid: uuid, x: x, y: y, z: z}, body: body, revision: 1}}
        end

      {_, _, count} =
        Enum.reduce(Enum.with_index(c["ticks"]), {entries, world, count}, fn {row, tick},
                                                                             {entries, world,
                                                                              count} ->
          # The loot seeds vanilla's random sequences gave this tick, in mob order.
          seeds =
            for r <- row,
                s <- r["sounds"],
                s["loot_seed"] != nil,
                do: String.to_integer(s["loot_seed"])

          world = %{world | time: 1001 + tick, loot_seeds: seeds}

          # Hits between ticks, each as a player's attack (VMC-037n's one path).
          {entries, hurt_events} =
            Enum.reduce(c["hurts"], {entries, %{}}, fn h, {entries, events} ->
              if h["tick"] == tick do
                {id, entry} = Enum.at(entries, h["mob"])
                p = Enum.at(players, h["player"])

                hit = %{
                  source: DamageSource.new(:player_attack),
                  amount: float.(h["amount"]),
                  attacker: %{
                    uuid: p.uuid,
                    entity_id: p.id,
                    player: true,
                    type: "minecraft:player",
                    mainhand: nil
                  },
                  direct: %{
                    uuid: p.uuid,
                    entity_id: p.id,
                    player: true,
                    type: "minecraft:player",
                    mainhand: nil
                  },
                  position: {p.x, p.y, p.z}
                }

                {body, made, _} = Combat.hurt_body(entry.body, entry.entity, hit)

                {List.replace_at(entries, h["mob"], {id, %{entry | body: body}}),
                 Map.put(events, id, made)}
              else
                {entries, events}
              end
            end)

          # The bodies' timers (the hurt cooldown) run as the owner's ageing does.
          entries =
            Enum.map(entries, fn {id, entry} ->
              {body, _, _} = Body.tick(entry.body)
              {id, %{entry | body: body}}
            end)

          {steps, world} = MobTicks.steps(kernel_view, entries, world, nil)

          unless length(steps) == length(entries),
            do: raise("#{c["name"]} tick #{tick}: a mob did not tick")

          for step <- steps, effect <- step.effects do
            case effect do
              {:take_block, cell, taken} ->
                Process.put({:mob_ai_edit, cell}, Valimc.Data.BlockFacts.fluid_remains(taken))

              {:place_carried, cell, carried} ->
                Process.put({:mob_ai_edit, cell}, carried)

              _ ->
                :ok
            end
          end

          entries =
            Enum.zip_with(entries, steps, fn {id, entry}, step ->
              {x, y, z} = step.position
              {id, %{entry | body: step.body, entity: %{entry.entity | x: x, y: y, z: z}}}
            end)

          checks =
            Enum.zip_with([entries, steps, row], fn [{id, entry}, step, expected] ->
              body = entry.body
              mind = body.mob.ai
              {x, y, z} = step.position

              target =
                case mind.target do
                  {:player, <<_::64, n::64>>} -> n
                  nil -> nil
                  {:mob, _} -> :mob
                end

              path =
                case mind.navigation.path do
                  %{nodes: nodes, index: index} when index < tuple_size(nodes) ->
                    {nx, ny, nz} = elem(nodes, index)
                    [nx, ny, nz, hex.(mind.navigation.speed)]

                  _ ->
                    nil
                end

              # Melee hits with what they add, and a guardian's beam and thorns.
              hits =
                for effect <- step.effects,
                    hit = hit_of.(effect, step.effects),
                    hit != nil,
                    do: hit

              # A guardian's entity events (the oracle records only theirs).
              entity_events =
                if body.type in ~w(minecraft:guardian minecraft:elder_guardian),
                  do: for({:event, n} <- step.events, do: n),
                  else: []

              sounds =
                for event <- Map.get(hurt_events, id, []) ++ step.events,
                    {name, volume, pitch} <- sound_of.(event),
                    do: {sound_name.(name), bits.(volume), bits.(pitch)}

              # A skeleton's shot sounds where it shot, from the owner (VMC-043b3).
              sounds =
                sounds ++
                  for {:shoot, %{pitch: pitch}} <- step.effects,
                      do: {"minecraft:entity.skeleton.shoot", bits.(1.0), bits.(pitch)}

              # A cube's attack sound as a player touches it (VMC-043d).
              sounds =
                sounds ++
                  for {:touch, _, _, {name, volume, pitch}} <- step.effects,
                      do: {sound_name.(name), bits.(volume), bits.(pitch)}

              swings = for {:swing, hand} <- step.events, do: "#{hand}:whack:6"

              want_sounds =
                for s <- expected["sounds"],
                    s["sound"] != nil,
                    not String.ends_with?(s["sound"], ".step"),
                    do: {s["sound"], s["volume"], s["pitch"]}

              want_swings = for s <- expected["sounds"], s["swing"] != nil, do: s["swing"]

              want_hits =
                for h <- expected["hits"],
                    do: {h["player"], h["effect"], h["duration"], h["ignite"]}

              want_entity_events =
                for s <- expected["sounds"], s["entity_event"], do: s["entity_event"]

              takes = for {:pickup, _, n} <- step.effects, do: n
              want_takes = for s <- expected["sounds"], s["take"] != nil, do: s["take"]

              level_events =
                for {:level_event, {cx, cy, cz}, type, data} <- step.effects,
                    do: [type, [cx, cy, cz], data]

              # A woken infested block's break event (`destroyBlock`).
              level_events =
                level_events ++
                  for {:wake_infested, {cx, cy, cz}, state, true} <- step.effects,
                      do: [2001, [cx, cy, cz], state]

              want_events =
                for s <- expected["sounds"],
                    s["event"] != nil,
                    do: [s["event"], s["at"], s["data"]]

              # The blocks an enderman took or put down (VMC-043b5).
              blocks =
                for effect <- step.effects,
                    edit =
                      (case effect do
                         {:take_block, {bx, by, bz}, taken} ->
                           [[bx, by, bz], Valimc.Data.BlockFacts.fluid_remains(taken)]

                         {:place_carried, {bx, by, bz}, carried} ->
                           [[bx, by, bz], carried]

                         # A silverfish's stone and the friends it wakes (VMC-043b6).
                         {:infest, {bx, by, bz}, infested} ->
                           [[bx, by, bz], infested]

                         {:wake_infested, {bx, by, bz}, state, true} ->
                           [[bx, by, bz], Valimc.Data.BlockFacts.fluid_remains(state)]

                         {:wake_infested, {bx, by, bz}, state, false} ->
                           [[bx, by, bz], Valimc.AI.Mobs.Silverfish.host_of(state)]

                         _ ->
                           nil
                       end),
                    edit != nil,
                    do: edit

              want_blocks =
                for s <- expected["sounds"], s["block"] != nil, do: [s["block"], s["state"]]

              # A creeper's explosion where it stood (VMC-043b4).
              want_blasts =
                for s <- expected["sounds"], s["explode"] != nil, do: [s["explode"], s["at"]]

              blasts =
                for {:explode, blast} <- step.effects,
                    do: [bits.(blast.radius), Enum.map(Tuple.to_list(blast.center), hex)]

              adds =
                for effect <- step.effects,
                    added = added.(effect),
                    added != nil,
                    do: added

              # A skeleton's arrow (VMC-043b3) where it was loosed: its own
              # random draws its flight, so only its type and start compare.
              adds =
                adds ++
                  for {:shoot, %{from: {fx, fy, fz}}} <- step.effects,
                      do: ["minecraft:arrow", Enum.map([fx, fy - 0.10000000149011612, fz], hex)]

              # A silverfish out of each infested block it woke (VMC-043b6).
              adds =
                adds ++
                  for {:wake_infested, {bx, by, bz}, _, true} <- step.effects,
                      do: [
                        "minecraft:silverfish",
                        Enum.map([bx + 0.5, by * 1.0, bz + 0.5], hex),
                        Enum.map([0.0, 0.0, 0.0], hex),
                        bits.(0.0),
                        bits.(0.0)
                      ]

              # A witch's splash potion where it was thrown (VMC-043b6): its own
              # random draws its spread, so its type, start and potion compare.
              adds =
                adds ++
                  for {:throw_potion, %{from: from, stack: stack}} <- step.effects,
                      do: [
                        "minecraft:splash_potion",
                        Enum.map(Tuple.to_list(from), hex),
                        Valimc.Data.PotionTypes.name(
                          stack.components["minecraft:potion_contents"].potion
                        )
                      ]

              # A converted mob is a new one where the old one was (VMC-043b).
              adds =
                adds ++
                  for {:convert, type} <- step.effects,
                      do: [
                        type,
                        Enum.map(Tuple.to_list(step.position), hex),
                        Enum.map(Tuple.to_list(body.velocity), hex),
                        bits.(body.yaw),
                        bits.(body.pitch)
                      ]

              want_adds =
                for s <- expected["sounds"], s["add"] != nil do
                  cond do
                    s["add"] == "minecraft:arrow" -> [s["add"], s["position"]]
                    s["potion"] -> [s["add"], s["position"], s["potion"]]
                    s["item"] -> [s["add"], s["position"], s["velocity"], s["item"], s["count"]]
                    true -> [s["add"], s["position"], s["velocity"], s["yaw"], s["pitch"]]
                  end
                end

              got = %{
                position: Enum.map(Tuple.to_list({x, y, z}), hex),
                velocity: Enum.map(Tuple.to_list(body.velocity), hex),
                yaw: bits.(body.yaw),
                head: bits.(body.head_yaw),
                body: bits.(mind.body_yaw),
                pitch: bits.(body.pitch),
                seed: mind.random,
                goals: Enum.join(goal_names.(body, :goals), ","),
                targets: Enum.join(goal_names.(body, :targets), ","),
                target: target,
                aggressive: mind.aggressive,
                path: path,
                sounds: sounds,
                swings: swings,
                hits: hits,
                entity_events: entity_events,
                takes: takes,
                level_events: level_events,
                blasts: blasts,
                blocks: blocks,
                adds: adds,
                level_seed: world.random,
                ambient: mind.ambient,
                no_action: mind.no_action,
                health: bits.(body.mob.living.health.value),
                data: kind_data.(body)
              }

              got =
                if mind.brain,
                  do:
                    Map.merge(got, %{
                      behaviors: Valimc.AI.Brain.running(%Valimc.AI.Self{mind: mind}),
                      activity:
                        Valimc.AI.Brain.activity(%Valimc.AI.Self{mind: mind})
                        |> then(&(&1 && Atom.to_string(&1))),
                      offhand: offhand.(body.mob.equipment[:offhand]),
                      admiring: admiring.(mind),
                      gate_seeds:
                        for(
                          %{kind: Valimc.AI.Behavior.Gate} = b <-
                            Tuple.to_list(mind.brain.behaviors),
                          do: b.random
                        )
                    }),
                  else: got

              want = %{
                position: expected["position"],
                velocity: expected["velocity"],
                yaw: expected["yaw"],
                head: expected["head"],
                body: expected["body"],
                pitch: expected["pitch"],
                seed: expected["seed"],
                goals: expected["goals"],
                targets: expected["targets"],
                target: expected["target"],
                aggressive: expected["aggressive"],
                path: expected["path"],
                sounds: want_sounds,
                swings: want_swings,
                hits: want_hits,
                entity_events: want_entity_events,
                takes: want_takes,
                level_events: want_events,
                blasts: want_blasts,
                blocks: want_blocks,
                adds: want_adds,
                level_seed: expected["level_seed"],
                ambient: expected["ambient"],
                no_action: expected["no_action"],
                health: expected["health"],
                data: expected["data"]
              }

              # Health and a family's own data, where the oracle reports them.
              want = Map.reject(want, fn {k, v} -> k in [:health, :data] and v == nil end)

              want =
                if mind.brain,
                  do:
                    Map.merge(want, %{
                      behaviors: expected["behaviors"],
                      activity: expected["activity"],
                      offhand:
                        expected["offhand"] && Valimc.Protocol.ItemTypes.id(expected["offhand"]),
                      admiring: expected["admiring"],
                      gate_seeds: expected["gate_seeds"]
                    }),
                  else: want

              {got, want} =
                if expected["fire"] != nil do
                  ours = extras.(body, step)

                  {Map.merge(got, Map.new(ours, fn {k, v} -> {String.to_atom(k), v} end)),
                   Map.merge(want, Map.new(Map.keys(ours), &{String.to_atom(&1), expected[&1]}))}
                else
                  {got, want}
                end

              # A mob its AI removed mid-tick (a silverfish slipping into
              # stone) does not move on: where it would have is moot.
              want =
                if :discard in step.effects,
                  do: Map.drop(want, [:position, :velocity]),
                  else: want

              differ = for {k, v} <- want, got[k] != v, do: {k, v, got[k]}

              unless differ == [] do
                raise "#{c["name"]} tick #{tick} mob #{id}: " <>
                        Enum.map_join(differ, "; ", fn {k, v, g} ->
                          "#{k} vanilla #{inspect(v)} ours #{inspect(g)}"
                        end)
              end

              1
            end)

          {entries, world, count + Enum.sum(checks)}
        end)

      count
  end

IO.puts(
  "PASS: #{checked} mob AI ticks of #{length(cases)} scenes equal vanilla's (goals, targets, brains, rotations, paths, randoms, hits, sounds, item takes, level events, added entities)"
)
