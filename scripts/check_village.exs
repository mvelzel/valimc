# Vanilla villagers ticking with their own brains over scenes with beds, job
# sites and bells (VillageOracle cases) against the owner's mob tick
# (VMC-044a1): each scene's blocks as a supplied view (a bed's `occupied`
# and a door's `open` follow the villagers' effects), the mobs' and their
# brains' randoms and the level random seeded alike, vanilla's path search
# over the same view, and the brain's activities walked in the oracle's
# order. Every tick, each mob's motion, rotations and random, a villager's
# running behaviours, activity, profession, POI, walk and look memories,
# sleeping place and path, the level random, the tickets taken of each POI
# and its block state must equal vanilla's.
#
# `--native` (VMC-081d): every mob takes its turns in a native section
# (`MobTicks.native_steps/7`), a villager's brain built natively with the
# oracle's gates, activity order, sensor countdowns and remade brains' gates
# (`mob_section_oracle_villager`); melee hits land in the section within the
# attacker's turn, as vanilla's do, and the checks read each mob's body,
# mind and brain from its section.
alias Valimc.AI
alias Valimc.AI.Brains.Villager
alias Valimc.Entity.{Body, Combat, MobTicks, NativeMobs, Store}
alias Valimc.Native
invisibility = Valimc.Data.EffectTypes.id("invisibility")

{native, argv} = Enum.split_with(System.argv(), &(&1 == "--native"))
native? = native != []
[path] = argv
if native?, do: NativeMobs.install!()
native_ticks = :counters.new(1, [])
Valimc.Data.BlockFacts.install!()
{fixtures, :ok, ""} = :json.decode(File.read!(path), :ok, %{null: nil})
cases = fixtures["cases"]
unless length(cases) >= 6, do: raise("Incomplete villager traces")

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

sound_names =
  for file <- ["priv/registry/ai_facts.json", "priv/registry/village_facts.json"],
      {n, id} <- :json.decode(File.read!(file))["sounds"],
      into: %{},
      do: {id, n}

# A scene packed as the kernel and the path search read it, made again only
# when the scene changed (a bed's state).
packed = fn scene ->
  key = {:packed, :erlang.phash2(scene)}

  case Process.get(key) do
    nil ->
      bin =
        for x <- -16..16, y <- 56..80, z <- -16..16, into: <<>> do
          <<x::signed-32, y::signed-32, z::signed-32, Map.get(scene, {x, y, z}, air)::16>>
        end

      Process.put(key, bin)
      bin

    bin ->
      bin
  end
end

property = fn state, key ->
  {_, v} = List.keyfind(Valimc.Data.Blocks.properties(state), key, 0)
  v
end

with_property = fn state, key, value ->
  props = state |> Valimc.Data.Blocks.properties() |> Map.new() |> Map.put(key, value)
  Valimc.Data.Blocks.state(Valimc.Data.Blocks.name(Valimc.Data.Blocks.block_id(state)), props)
end

# A bed's `occupied` set on its head, and its foot following (`updateShape`).
set_bed = fn scene, {x, y, z} = head, occupied ->
  state = scene[head]
  facing = property.(state, "facing")
  {dx, dz} = %{"north" => {0, -1}, "south" => {0, 1}, "west" => {-1, 0}, "east" => {1, 0}}[facing]
  foot = {x - dx, y, z - dz}
  value = to_string(occupied)
  scene = Map.put(scene, head, with_property.(state, "occupied", value))

  case scene[foot] do
    nil -> scene
    f -> Map.put(scene, foot, with_property.(f, "occupied", value))
  end
end

tracker = fn
  nil -> nil
  {:block, pos, _} -> %{"block" => Tuple.to_list(pos)}
  {:entity, {_, <<n::64, _::64>>}, _} -> %{"entity" => n}
  {:entity, {_, <<n::64, _::64>>}, _, _} -> %{"entity" => n}
end

global = fn
  nil -> nil
  {_, pos} -> Tuple.to_list(pos)
end

sound_name = fn
  id when is_integer(id) -> sound_names[id]
  name -> name
end

memory = fn mind, name ->
  case mind.brain.memories do
    %{^name => {value, _}} -> value
    _ -> nil
  end
end

# A native mob as the checks read it: its record's body, its mind and brain
# from its section.
native_body = fn ref, id ->
  [record] = Native.mob_section_records(ref, [id])
  {:ok, body} = Body.restore(record)

  m =
    Native.mob_section_oracle_mind(ref, id) ||
      %{body_yaw: body.yaw, goals: [], targets: [], target: nil, path: nil, ambient: 0}

  brain =
    case Native.mob_section_oracle_brain_view(ref, id) do
      {running, activity, _, memories} ->
        %{
          native: true,
          running: running,
          activity: activity && Atom.to_string(activity),
          memories:
            Map.new(memories, fn {name, value, ttl} -> {String.to_atom(name), {value, ttl}} end)
        }

      nil ->
        nil
    end

  mind = %{
    body_yaw: m.body_yaw,
    random: record.mob.ai.random,
    goals: m.goals,
    targets: m.targets,
    target: m.target,
    navigation:
      case m.path do
        {x, y, z, speed} -> %{path: %{nodes: {{x, y, z}}, index: 0}, speed: speed}
        nil -> %{path: nil, speed: 0.0}
      end,
    ambient: m.ambient,
    brain: brain
  }

  put_in(body.mob.ai, mind)
end

# A native mob of `entry` (its body as the harness made it) in section
# `ref`: `{id, entry}` with its row.
native_insert = fn ref, id, entry ->
  e = entry.entity
  record = Store.body_record(entry.body, e.uuid, {e.x, e.y, e.z})
  {:ok, [{^id, _, row}]} = Native.mob_section_insert(ref, [{id, record}], false)
  :ok = Native.mob_section_oracle_prepare(ref, id, entry.body.mob.ai.body_yaw, nil)
  {id, entry |> Map.put(:body, row) |> Map.merge(%{native: ref, made: entry.body})}
end

checked =
  for c <- cases, reduce: 0 do
    count ->
      scene0 = Map.new(c["blocks"], fn [x, y, z, s] -> {{x, y, z}, s} end)
      pois = Enum.map(c["pois"], &List.to_tuple/1)
      start = c["start"]

      world0 = fn scene, time ->
        view = {:states, packed.(scene)}

        %AI.World{
          read: &Map.get(scene, &1, air),
          find: fn {x0, y0, z0, x1, y1, z1}, states ->
            for {{x, y, z} = p, s} <- scene,
                x in x0..x1 and y in y0..y1 and z in z0..z1 and MapSet.member?(states, s),
                do: {p, s}
          end,
          search: fn request ->
            [result] = AI.Paths.find(view, [request])
            result
          end,
          stand_up: fn _type, head, facing, yaw ->
            dense =
              for x <- -16..16,
                  y <- 56..80,
                  z <- -16..16,
                  into: %{},
                  do: {{x, y, z}, Map.get(scene, {x, y, z}, air)}

            Valimc.World.StandUp.bed(Valimc.World.View.of(dense), head, facing, yaw)
          end,
          sky: fn {x, y, z} ->
            not Enum.any?(scene, fn {{bx, by, bz}, s} ->
              bx == x and bz == z and by > y and s != air
            end)
          end,
          random: AI.Random.new(7),
          difficulty: :normal,
          time: time,
          day: time,
          # A scene that follows the sky (a trader's, VMC-044a4): bright while
          # the overworld's sky darkens by less than 4.
          bright:
            c["real_sky"] == true and
              Valimc.World.Spawning.darken("minecraft:overworld", time, 0.0, 0.0) < 4
        }
      end

      gate_map = fn rows -> Map.new(rows, fn [key, seed] -> {key, AI.Random.new(seed)} end) end

      world = world0.(scene0, start)

      entries =
        for {m, i} <- Enum.with_index(c["mobs"]) do
          yaw = float.(m["yaw"])
          {:ok, body} = Body.new(m["type"])
          {x, y, z} = vector.(m["position"])
          uuid = <<m["id"]::64, 0::64>>

          body =
            case m["type"] do
              "minecraft:villager" ->
                data = %{body.data | age: m["age"]}
                data = if m["profession"], do: %{data | profession: m["profession"]}, else: data
                %{body | data: data}

              _ ->
                body
            end

          mind = AI.mind(m["type"], uuid, %{random: AI.Random.new(m["seed"])}, body.data, nil)

          mind =
            case m["type"] do
              "minecraft:villager" ->
                {brain, _} =
                  Villager.brain(
                    AI.Random.new(0),
                    gate_map.(Enum.at(c["gates"], i)),
                    body.data,
                    Map.new(Enum.at(c["orders"], i), fn {p, acts} ->
                      {String.to_integer(p), Enum.map(acts, &String.to_atom/1)}
                    end)
                  )

                sensors =
                  Enum.zip_with(brain.sensors, Enum.at(c["sensors"], i), fn s, t ->
                    %{s | time: t}
                  end)

                refresh =
                  for row <- c["ticks"],
                      %{"reseeded" => seeds} <- [Enum.at(row["mobs"], i)],
                      do: gate_map.(seeds)

                mind = %{mind | brain: %{brain | sensors: sensors, refresh: refresh}}

                Villager.started(%AI.Self{
                  uuid: uuid,
                  type: m["type"],
                  mind: mind,
                  world: world,
                  data: body.data
                }).mind

              _ ->
                mind
            end

          mind = %{mind | random: AI.Random.new(m["seed"]), body_yaw: yaw}

          # What a native villager's brain is built with.
          seeding =
            if m["type"] == "minecraft:villager" do
              keyed = fn rows -> for [key, seed] <- rows, do: {key, AI.Random.new(seed)} end

              {keyed.(Enum.at(c["gates"], i)),
               for({p, acts} <- Enum.at(c["orders"], i), do: {String.to_integer(p), acts}),
               Enum.at(c["sensors"], i),
               for(
                 row <- c["ticks"],
                 %{"reseeded" => seeds} <- [Enum.at(row["mobs"], i)],
                 do: keyed.(seeds)
               ), {start, start, AI.Random.new(m["seed"]), if(m["slept"] >= 0, do: m["slept"])}}
            end

          # When it last slept (a golem's summoners).
          mind =
            if mind.brain && m["slept"] >= 0,
              do: put_in(mind.brain.memories[:last_slept], {m["slept"], :never}),
              else: mind

          mob = %{body.mob | ai: mind, no_ai: m["no_ai"]}

          # A wandering trader's setup (VMC-044a4): its wander target and
          # home, despawn delay, and invisibility.
          {body, mob} =
            case m["trader"] do
              nil ->
                {body, mob}

              t ->
                wander = t["wander"] && List.to_tuple(t["wander"])

                data = %{
                  body.data
                  | despawn_delay: t["despawn"],
                    wander_target: wander,
                    invisible: t["invisible"]
                }

                effects =
                  if t["invisible"],
                    do: %{invisibility => [{3600, 0, false, true, true}]},
                    else: %{}

                mob = %{
                  mob
                  | home: wander && {wander, 16},
                    living: %{mob.living | effects: effects}
                }

                {%{body | data: data}, mob}
            end

          # Scenery takes no knockback (the oracle's too).
          mob =
            if m["no_ai"],
              do: %{
                mob
                | attributes:
                    Map.put(mob.attributes, "minecraft:knockback_resistance", %{
                      base: 1.0,
                      modifiers: []
                    })
              },
              else: mob

          body = %{body | yaw: yaw, head_yaw: yaw, mob: mob}

          {m["id"],
           %{
             kind: :mob,
             entity: %{uuid: uuid, entity_id: m["id"], x: x, y: y, z: z},
             body: body,
             revision: 1,
             seeding: seeding
           }}
        end

      # A native mode's section, every mob there from its record.
      section =
        if native?, do: %NativeMobs{ref: Native.mob_section_oracle_new(), types: MapSet.new()}

      entries =
        if native? do
          for {id, entry} <- entries do
            {id, native} = native_insert.(section.ref, id, entry)

            case entry.seeding do
              {gates, order, sensors, refresh, timing} ->
                :ok =
                  Native.mob_section_oracle_villager(
                    section.ref,
                    id,
                    gates,
                    order,
                    sensors,
                    refresh,
                    timing
                  )

              nil ->
                :ok
            end

            {id, native}
          end
        else
          entries
        end

      # A scene ends with the tick a mob held still dies: the owner lands a
      # kill after the tick, vanilla within the attacker's (its target goes a
      # tick later here).
      death =
        Enum.find_index(c["ticks"], fn row ->
          Enum.any?(Enum.zip(c["mobs"], row["mobs"]), fn {m, r} ->
            m["no_ai"] and float.(r["health"]) <= 0.0
          end)
        end)

      {_, _, _, count} =
        c["ticks"]
        |> Enum.take(if death, do: death + 1, else: length(c["ticks"]))
        |> Enum.with_index()
        |> Enum.reduce({entries, scene0, AI.Random.new(7), count}, fn
          {row, tick}, {entries, scene, level_random, count} ->
            time = start + 1 + tick

            memories =
              for {_, %{body: %{mob: %{ai: %AI.Mind{brain: %{memories: m}}}}}} <- entries, do: m

            world = %{world0.(scene, time) | random: level_random, pois: AI.Pois.claims(memories)}
            kernel_view = {:states, packed.(scene)}

            # Each body's timers (a hurt mob's invulnerability) run first, as
            # the owner ages its bodies.
            entries =
              for {id, e} <- entries do
                case e do
                  %{native: ref} ->
                    [{^id, _, row, _, _}] = Native.mob_section_age(ref, [{id, 1}], true)
                    {id, if(row, do: %{e | body: NativeMobs.merge(row, e.body)}, else: e)}

                  e ->
                    {body, _, _} = Body.tick(e.body)
                    {id, %{e | body: body}}
                end
              end

            {steps, world} =
              if native? do
                # The scene's sky: full light above each column's top block.
                tops =
                  for {{x, z}, y} <-
                        Enum.reduce(scene, %{}, fn
                          {_, ^air}, acc -> acc
                          {{x, y, z}, _}, acc -> Map.update(acc, {x, z}, y, &max(&1, y))
                        end),
                      do: {x, z, y}

                level = %{
                  time: time,
                  day: time,
                  difficulty: :normal,
                  darken: 0,
                  bright: world.bright,
                  monsters_burn: false,
                  halloween: false,
                  mob_griefing: true,
                  mob_drops: true,
                  entity_drops: true,
                  universal_anger: false,
                  goals: true,
                  min_y: -64,
                  max_y: 319,
                  sea_level: 63,
                  border: nil,
                  knots: [],
                  wet: false,
                  zoom_seed: 0,
                  tops: tops,
                  no_chunks: true
                }

                env = %{region: nil, level: level, players: [], items: [], reach: 0}
                MobTicks.native_steps(kernel_view, entries, world, nil, [], section, env)
              else
                MobTicks.steps(kernel_view, entries, world, nil)
              end

            unless length(steps) == length(entries),
              do: raise("#{c["name"]} tick #{tick}: a mob did not tick")

            # A mob held still does not travel (vanilla's `isEffectiveAi`): the
            # owner's kernel moves every mob, so scenery stays where it was.
            entries =
              Enum.zip_with(entries, steps, fn {id, entry}, step ->
                no_ai =
                  case entry do
                    %{native: _} -> step.body.no_ai
                    _ -> entry.body.mob.no_ai
                  end

                {x, y, z} =
                  if no_ai,
                    do: {entry.entity.x, entry.entity.y, entry.entity.z},
                    else: step.position

                {id, %{entry | body: step.body, entity: %{entry.entity | x: x, y: y, z: z}}}
              end)

            # Melee hits on mobs through the one hurt path (`Combat`), as
            # the owner lands them after the tick.
            entries =
              for step <- steps,
                  not native?,
                  effect <- step.effects,
                  {target, own} <-
                    (case effect do
                       {:attack, {:mob, t}} ->
                         [
                           {t,
                            Enum.find_value(step.effects, %{}, fn
                              {:attack_extra, {:mob, ^t}, extras} -> extras
                              _ -> nil
                            end)}
                         ]

                       _ ->
                         []
                     end),
                  reduce: entries do
                entries ->
                  store = %{entries: Map.new(entries)}
                  i = Enum.find_index(entries, fn {_, e} -> e.entity.uuid == target end)
                  {tid, te} = Enum.at(entries, i)
                  {:ok, hit} = Combat.mob_hit(store, step.id, te.body.type)

                  hit =
                    Map.merge(
                      %{hit | amount: own[:amount] || hit.amount},
                      Map.delete(own, :amount)
                    )

                  case Combat.hurt_body(te.body, te.entity, hit) do
                    :ignored -> entries
                    {body, _, _} -> List.replace_at(entries, i, {tid, %{te | body: body}})
                  end
              end

            # Mobs the mobs summoned (a golem), ticking from the next tick
            # with the oracle's ids and randoms.
            summoned = for step <- steps, {:spawn, type, opts} <- step.effects, do: {type, opts}

            spawned =
              for {{type, opts}, made} <- Enum.zip(summoned, row["spawned"]) do
                ^type = made["type"]
                {:ok, body} = Body.new(type)
                uuid = <<made["id"]::64, 0::64>>

                mind =
                  AI.mind(type, uuid, %{random: AI.Random.new(made["seed"])}, body.data, world)

                follow = %{
                  base: nil,
                  modifiers: [{"minecraft:random_spawn_bonus", opts.follow_bonus, 1}]
                }

                mob = %{
                  body.mob
                  | ai: %{mind | body_yaw: opts.yaw},
                    left_handed: opts.left_handed,
                    attributes: Map.put(body.mob.attributes, "minecraft:follow_range", follow)
                }

                {x, y, z} = opts.position

                {made["id"],
                 %{
                   kind: :mob,
                   entity: %{uuid: uuid, entity_id: made["id"], x: x, y: y, z: z},
                   body: %{body | yaw: opts.yaw, head_yaw: opts.yaw, mob: mob},
                   revision: 1
                 }}
              end

            entries =
              entries ++
                if native?,
                  do: for({id, e} <- spawned, do: native_insert.(section.ref, id, e)),
                  else: spawned

            scene =
              for step <- steps, effect <- step.effects, reduce: scene do
                scene ->
                  case effect do
                    {:bed, pos, occupied} -> set_bed.(scene, pos, occupied)
                    _ -> scene
                  end
              end

            claims =
              AI.Pois.claims(
                for {id, e} <- entries,
                    m =
                      (case e do
                         %{native: ref} ->
                           case native_body.(ref, id).mob.ai.brain do
                             %{memories: m} -> m
                             _ -> nil
                           end

                         %{body: %{mob: %{ai: %AI.Mind{brain: %{memories: m}}}}} ->
                           m

                         _ ->
                           nil
                       end),
                    m != nil,
                    do: m
              )

            taken = for p <- pois, do: Map.get(claims, p, 0)
            states = for p <- pois, do: Map.get(scene, p, air)

            unless taken == row["taken"] and states == row["states"] do
              raise "#{c["name"]} tick #{tick}: POIs vanilla #{inspect({row["taken"], row["states"]})} ours #{inspect({taken, states})}"
            end

            unless world.random == row["level_seed"] do
              raise "#{c["name"]} tick #{tick}: level random vanilla #{row["level_seed"]} ours #{world.random}"
            end

            checks =
              Enum.zip_with([entries, steps, row["mobs"]], fn [{id, entry}, step, expected] ->
                body =
                  case entry do
                    %{native: ref} ->
                      :counters.add(native_ticks, 1, 1)
                      native_body.(ref, id)

                    _ ->
                      entry.body
                  end

                mind = body.mob.ai
                {x, y, z} = step.position

                path =
                  case mind.navigation.path do
                    %{nodes: nodes, index: index} when index < tuple_size(nodes) ->
                      {nx, ny, nz} = elem(nodes, index)
                      [nx, ny, nz, hex.(mind.navigation.speed)]

                    _ ->
                      nil
                  end

                sounds =
                  for {:sound, name, _, volume, pitch, _} <- step.events,
                      do: {sound_name.(name), bits.(volume), bits.(pitch)}

                want_sounds =
                  for s <- expected["sounds"],
                      s["sound"] != nil,
                      not String.ends_with?(s["sound"], ".step"),
                      do: {s["sound"], s["volume"], s["pitch"]}

                got = %{
                  position: Enum.map(Tuple.to_list({x, y, z}), hex),
                  velocity: Enum.map(Tuple.to_list(body.velocity), hex),
                  yaw: bits.(body.yaw),
                  head: bits.(body.head_yaw),
                  body: bits.(mind.body_yaw),
                  pitch: bits.(body.pitch),
                  seed: mind.random,
                  path: path,
                  sounds: sounds,
                  ambient: mind.ambient
                }

                want = %{
                  position: expected["position"],
                  velocity: expected["velocity"],
                  yaw: expected["yaw"],
                  head: expected["head"],
                  body: expected["body"],
                  pitch: expected["pitch"],
                  seed: expected["seed"],
                  path: expected["path"],
                  sounds: want_sounds,
                  ambient: expected["ambient"]
                }

                goal_names = fn which ->
                  {goals, targets} = AI.Mobs.registered(body.type)
                  registered = if which == :goals, do: goals, else: targets
                  running = if which == :goals, do: mind.goals, else: mind.targets

                  if is_list(running) do
                    # A native mind's running goals by registration index.
                    for {i, name} <- running do
                      if String.starts_with?(name, "Valimc."),
                        do: elem(Enum.at(registered, i), 1),
                        else: name
                    end
                  else
                    entries = Tuple.to_list(running)

                    for {%{running: true}, {_, name, _, _, _}} <- Enum.zip(entries, registered),
                        do: name
                  end
                end

                got = Map.put(got, :health, bits.(body.mob.living.health.value))
                want = Map.put(want, :health, expected["health"])

                {got, want} =
                  if mind.brain == nil do
                    {Map.merge(got, %{
                       goals: Enum.join(goal_names.(:goals), ","),
                       targets: Enum.join(goal_names.(:targets), ","),
                       target:
                         case mind.target do
                           {:mob, <<n::64, _::64>>} -> n
                           {:player, <<_::64, n::64>>} -> n
                           nil -> nil
                         end
                     }),
                     Map.merge(want, %{
                       goals: expected["goals"],
                       targets: expected["targets"],
                       target: expected["target"]
                     })}
                  else
                    {got, want}
                  end

                {got, want} =
                  if mind.brain do
                    self = %AI.Self{mind: mind}

                    {behaviors, activity} =
                      case mind.brain do
                        %{native: true} = b ->
                          {b.running, b.activity}

                        _ ->
                          {AI.Brain.running(self),
                           AI.Brain.activity(self) |> then(&(&1 && Atom.to_string(&1)))}
                      end

                    walk =
                      case memory.(mind, :walk_target) do
                        nil ->
                          nil

                        w ->
                          %{
                            "target" => tracker.(w.target),
                            "speed" => bits.(w.speed),
                            "close" => w.close
                          }
                      end

                    {Map.merge(got, %{
                       behaviors: behaviors,
                       activity: activity,
                       profession: body.data.profession,
                       home: global.(memory.(mind, :home)),
                       job_site: global.(memory.(mind, :job_site)),
                       potential_job_site: global.(memory.(mind, :potential_job_site)),
                       meeting_point: global.(memory.(mind, :meeting_point)),
                       walk_target: walk,
                       look_target: tracker.(memory.(mind, :look_target)),
                       sleeping: body.data.sleeping && Tuple.to_list(body.data.sleeping),
                       hostile:
                         case memory.(mind, :nearest_hostile) do
                           {_, <<n::64, _::64>>} -> n
                           nil -> nil
                         end
                     }),
                     Map.merge(want, %{
                       behaviors: expected["behaviors"],
                       activity: expected["activity"],
                       profession: expected["profession"],
                       home: expected["home"],
                       job_site: expected["job_site"],
                       potential_job_site: expected["potential_job_site"],
                       meeting_point: expected["meeting_point"],
                       walk_target: expected["walk_target"],
                       look_target: expected["look_target"],
                       sleeping: expected["sleeping"],
                       hostile: expected["hostile"]
                     })}
                  else
                    {got, want}
                  end

                # A wandering trader's hand, drink, invisibility, despawn
                # delay and wander target (VMC-044a4).
                {got, want} =
                  if body.type == "minecraft:wandering_trader" do
                    stack = body.mob.equipment[:mainhand]

                    using =
                      case body.mob.using do
                        {_, used} ->
                          Valimc.Living.FoodItems.properties(stack).consumable["ticks"] - used

                        nil ->
                          0
                      end

                    duration =
                      case body.mob.living.effects[invisibility] do
                        [{ticks, _, _, _, _} | _] -> ticks
                        nil -> -1
                      end

                    {Map.merge(got, %{
                       mainhand:
                         if(stack,
                           do: Valimc.Protocol.ItemTypes.item(stack.item_id)["name"],
                           else: "minecraft:air"
                         ),
                       using: using,
                       invisibility: duration,
                       invisible: body.data.invisible,
                       despawn: body.data.despawn_delay,
                       wander: body.data.wander_target && Tuple.to_list(body.data.wander_target)
                     }),
                     Map.merge(
                       want,
                       Map.new(
                         ~w(mainhand using invisibility invisible despawn wander),
                         &{String.to_atom(&1), expected[&1]}
                       )
                     )}
                  else
                    {got, want}
                  end

                if System.get_env("VILLAGE_DEBUG") == "#{c["name"]}:#{tick}",
                  do:
                    IO.inspect(
                      {tick, id, step.position, body.velocity},
                      label: "ours"
                    )

                # A mob held still (`NoAI`) is only scenery here: vanilla neither
                # moves nor thinks for it, and it stands where it was put.
                differ =
                  cond do
                    # The death tick: the kill is what it checks.
                    tick == death and body.mob.no_ai ->
                      if got.health == want.health,
                        do: [],
                        else: [{:health, want.health, got.health}]

                    tick == death ->
                      []

                    body.mob.no_ai ->
                      []

                    true ->
                      for {k, v} <- want, got[k] != v, do: {k, v, got[k]}
                  end

                unless differ == [] do
                  raise "#{c["name"]} tick #{tick} mob #{id}: " <>
                          Enum.map_join(differ, "; ", fn {k, v, g} ->
                            "#{k} vanilla #{inspect(v)} ours #{inspect(g)}"
                          end)
                end

                1
              end)

            {entries, scene, world.random, count + Enum.sum(checks)}
        end)

      count
  end

IO.puts(
  "PASS: #{checked} villager ticks of #{length(cases)} scenes equal vanilla's (brains, schedules, POIs, beds, professions, motion, randoms)" <>
    if(native?, do: ", #{:counters.get(native_ticks, 1)} of them native", else: "")
)
