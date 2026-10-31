# Vanilla villagers ticking with their own brains over scenes with beds, job
# sites and bells (VillageOracle cases) against the owner's mob tick
# (VMC-044a1): each scene's blocks as a supplied view (a bed's `occupied`
# and a door's `open` follow the villagers' effects), the mobs' and their
# brains' randoms and the level random seeded alike, vanilla's path search
# over the same view, and the brain's activities walked in the oracle's
# order. Every tick, each mob's motion, rotations and random, a villager's
# running behaviours, activity, profession, POI, walk and look memories,
# sleeping place and path, the level random, the tickets taken of each POI
# and its block state, and its offers' uses and demand and its restocks
# (VMC-044b3), must equal vanilla's.
#
# Every mob takes its turns in a native section (`MobTicks.native_steps/4`,
# VMC-081d), a villager's brain built with the oracle's gates, activity
# order, sensor countdowns and remade brains' gates
# (`mob_section_oracle_villager`); melee hits land in the section within the
# attacker's turn, as vanilla's do, and the checks read each mob's body,
# mind and brain from its section.
alias Valimc.Data.JavaRandom
alias Valimc.Entity.{Body, MobTicks, NativeMobs, Store}
alias Valimc.Native
invisibility = Valimc.Data.EffectTypes.id("invisibility")

[path] = System.argv()
Valimc.Entity.MobFacts.install!()
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

# The POI tickets the villagers' memories take (`PoiManager`'s tickets of
# their home, job site, potential job site and meeting point), by block.
claims_of = fn memories ->
  for m <- memories,
      name <- [:home, :job_site, :potential_job_site, :meeting_point],
      {{_dimension, pos}, _ttl} <- [m[name]],
      reduce: %{},
      do: (acc -> Map.update(acc, pos, 1, &(&1 + 1)))
end

# The goals and target goals each type registers, in order, by their
# vanilla names (MobAiOracle's facts).
registered =
  for {type, m} <- :json.decode(File.read!("priv/registry/ai_facts.json"))["mobs"],
      into: %{},
      do:
        {type,
         %{
           goals: Enum.map(m["goals"], &Enum.at(&1, 1)),
           targets: Enum.map(m["targets"], &Enum.at(&1, 1))
         }}

# A mob as the checks read it: its record's body, its mind and brain from
# its section.
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

# A mob of `entry` (its body as the harness made it, facing `body_yaw`) in
# section `ref`: `{id, entry}` with its row.
native_insert = fn ref, id, entry ->
  e = entry.entity
  record = Store.body_record(entry.body, e.uuid, {e.x, e.y, e.z})
  {:ok, [{^id, _, row}]} = Native.mob_section_insert(ref, [{id, record}], false)
  :ok = Native.mob_section_oracle_prepare(ref, id, entry.body_yaw, nil)
  {id, entry |> Map.put(:body, row) |> Map.merge(%{native: ref, made: entry.body})}
end

checked =
  for c <- cases, reduce: 0 do
    count ->
      scene0 = Map.new(c["blocks"], fn [x, y, z, s] -> {{x, y, z}, s} end)
      pois = Enum.map(c["pois"], &List.to_tuple/1)
      start = c["start"]

      # A scene that follows the sky (a trader's, VMC-044a4): bright while
      # the overworld's sky darkens by less than 4.
      bright = fn time ->
        c["real_sky"] == true and
          Valimc.World.Spawning.darken("minecraft:overworld", time, 0.0, 0.0) < 4
      end

      # The players standing in the scene (VMC-044c1), as MobAiOracle's.
      players =
        for p <- c["players"] || [] do
          {x, y, z} = vector.(p["position"])

          %{
            kind: :player,
            uuid: <<1::64, p["uuid"]::64>>,
            id: p["id"],
            x: x,
            y: y,
            z: z,
            yaw: 0.0,
            pitch: 0.0,
            eye: Valimc.Data.Float32.round(1.62),
            width: Valimc.Data.Float32.round(0.6),
            height: Valimc.Data.Float32.round(1.8),
            mode: :survival,
            invulnerable: false,
            alive: true,
            crouching: false,
            swimming: false,
            invisible: false,
            armor_cover: 0.0,
            equipment: %{mainhand: nil, offhand: nil, head: nil}
          }
        end

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

                # A shop scene's offers and restocks, with 5 experience (VMC-044b3).
                data =
                  case m["shop"] do
                    nil ->
                      data

                    shop ->
                      offers =
                        for [a, n, b, nb, sell, ns, uses, max, demand, multiplier, xp] <-
                              shop["offers"] do
                          %{
                            buy: Valimc.Protocol.ItemStack.new(a, n),
                            buy_b: b && Valimc.Protocol.ItemStack.new(b, nb),
                            sell: Valimc.Protocol.ItemStack.new(sell, ns),
                            uses: uses,
                            max_uses: max,
                            reward_exp: true,
                            special_price: 0,
                            demand: demand,
                            price_multiplier: Valimc.Data.Float32.round(multiplier * 1.0),
                            xp: xp
                          }
                        end

                      %{
                        data
                        | offers: offers,
                          last_restock: shop["last_restock"],
                          restocks_today: shop["restocks"],
                          xp: 5
                      }
                  end

                # Bread in its inventory (VMC-044c2).
                data =
                  case m["bread"] do
                    nil ->
                      data

                    n ->
                      %{
                        data
                        | inventory: [
                            Valimc.Protocol.ItemStack.new("minecraft:bread", n)
                            | List.duplicate(nil, 7)
                          ]
                      }
                  end

                # The bed it already claimed (VMC-044c2), its home as its
                # brain starts.
                data =
                  case m["home"] do
                    nil -> data
                    home -> %{data | home_bed: List.to_tuple(home)}
                  end

                # Its gossip at the start (VMC-044c1), added in order.
                data =
                  case m["gossip"] do
                    nil ->
                      data

                    rows ->
                      targets =
                        rows
                        |> Enum.map(&hd/1)
                        |> Enum.uniq()
                        |> Enum.map(fn n ->
                          {<<1::64, n::64>>,
                           for(
                             [^n, type, value] <- rows,
                             do: {String.to_atom(String.downcase(type)), value}
                           )}
                        end)

                      %{data | gossips: {targets, length(targets)}}
                  end

                %{body | data: data}

              _ ->
                body
            end

          # What a villager's brain is built with: the oracle's gates,
          # activity order, sensor countdowns and remade brains' gates, its
          # schedule's start, its random and when it last slept.
          seeding =
            if m["type"] == "minecraft:villager" do
              keyed = fn rows -> for [key, seed] <- rows, do: {key, JavaRandom.new(seed)} end

              {keyed.(Enum.at(c["gates"], i)),
               for({p, acts} <- Enum.at(c["orders"], i), do: {String.to_integer(p), acts}),
               Enum.at(c["sensors"], i),
               for(
                 row <- c["ticks"],
                 %{"reseeded" => seeds} <- [Enum.at(row["mobs"], i)],
                 do: keyed.(seeds)
               ), {start, start, JavaRandom.new(m["seed"]), if(m["slept"] >= 0, do: m["slept"])}}
            end

          mob = %{body.mob | ai: %{random: JavaRandom.new(m["seed"])}, no_ai: m["no_ai"]}

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
             body_yaw: yaw,
             revision: 1,
             seeding: seeding
           }}
        end

      # The scene's section, every mob there from its record.
      section = %NativeMobs{ref: Native.mob_section_oracle_new()}

      entries =
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
        |> Enum.reduce({entries, scene0, JavaRandom.new(7), count}, fn
          {row, tick}, {entries, scene, level_random, count} ->
            time = start + 1 + tick
            kernel_view = {:states, packed.(scene)}

            # Each body's timers (a hurt mob's invulnerability) run first, as
            # the owner ages its bodies.
            entries =
              for {id, %{native: ref} = e} <- entries do
                [{^id, _, row, _, _}] = Native.mob_section_age(ref, [{id, 1}], true)
                {id, if(row, do: %{e | body: NativeMobs.merge(row, e.body)}, else: e)}
              end

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
              bright: bright.(time),
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

            env = %{region: nil, level: level, players: players, items: [], random: level_random}

            {steps, %{random: level_random}} =
              MobTicks.native_steps(kernel_view, entries, section, env)

            unless length(steps) == length(entries),
              do: raise("#{c["name"]} tick #{tick}: a mob did not tick")

            # A mob held still does not travel (vanilla's `isEffectiveAi`): the
            # owner's kernel moves every mob, so scenery stays where it was.
            entries =
              Enum.zip_with(entries, steps, fn {id, entry}, step ->
                {x, y, z} =
                  if step.body.no_ai,
                    do: {entry.entity.x, entry.entity.y, entry.entity.z},
                    else: step.position

                {id, %{entry | body: step.body, entity: %{entry.entity | x: x, y: y, z: z}}}
              end)

            # A breeding villager's changes to its partner, which its owner
            # applies after the tick (VMC-044c2): the partner shows them from
            # the next tick, vanilla's at once.
            changed =
              for step <- steps,
                  {:merchant, :partner, <<n::64, _::64>>, change} <- step.effects,
                  uniq: true do
                {:ok, _} = Native.mob_section_merchant(section.ref, n, change)
                n
              end

            # A baby born (VMC-044c2): its type, age, bed and place as
            # vanilla's.
            for step <- steps,
                {:offspring, "minecraft:villager", data, {x, y, z}} <- step.effects do
              baby = Enum.find(row["spawned"], &Map.has_key?(&1, "villager_type"))

              want =
                {baby["villager_type"], baby["age"], baby["home"], vector.(baby["position"])}

              got =
                {data.villager_type, data.age, data.home_bed && Tuple.to_list(data.home_bed),
                 {x, y, z}}

              unless got == want,
                do: raise("#{c["name"]} tick #{tick}: baby #{inspect(got)} != #{inspect(want)}")
            end

            # Mobs the mobs summoned (a golem), ticking from the next tick
            # with the oracle's ids and randoms.
            summoned = for step <- steps, {:spawn, type, opts} <- step.effects, do: {type, opts}

            spawned =
              for {{type, opts}, made} <- Enum.zip(summoned, row["spawned"]) do
                ^type = made["type"]
                {:ok, body} = Body.new(type)
                uuid = <<made["id"]::64, 0::64>>

                follow = %{
                  base: nil,
                  modifiers: [{"minecraft:random_spawn_bonus", opts.follow_bonus, 1}]
                }

                mob = %{
                  body.mob
                  | ai: %{random: JavaRandom.new(made["seed"])},
                    left_handed: opts.left_handed,
                    attributes: Map.put(body.mob.attributes, "minecraft:follow_range", follow)
                }

                {x, y, z} = opts.position

                {made["id"],
                 %{
                   kind: :mob,
                   entity: %{uuid: uuid, entity_id: made["id"], x: x, y: y, z: z},
                   body: %{body | yaw: opts.yaw, head_yaw: opts.yaw, mob: mob},
                   body_yaw: opts.yaw,
                   revision: 1
                 }}
              end

            entries = entries ++ for({id, e} <- spawned, do: native_insert.(section.ref, id, e))

            scene =
              for step <- steps, effect <- step.effects, reduce: scene do
                scene ->
                  case effect do
                    {:bed, pos, occupied} -> set_bed.(scene, pos, occupied)
                    _ -> scene
                  end
              end

            claims =
              claims_of.(
                for {id, %{native: ref}} <- entries,
                    %{memories: m} <- [native_body.(ref, id).mob.ai.brain],
                    do: m
              )

            # A bed in a villager's data, its home once its brain starts
            # (VMC-044c2), which the owner's sections count too.
            claims =
              for {id, %{native: ref}} <- entries,
                  %{data: %{home_bed: {_, _, _} = bed}} <- [native_body.(ref, id)],
                  reduce: claims,
                  do: (acc -> Map.update(acc, bed, 1, &(&1 + 1)))

            # A baby's bed from its birth this tick (VMC-044c2), which the
            # owner's sections count from its data.
            claims =
              for step <- steps,
                  {:offspring, _, %{home_bed: {_, _, _} = bed}, _} <- step.effects,
                  reduce: claims,
                  do: (acc -> Map.update(acc, bed, 1, &(&1 + 1)))

            taken = for p <- pois, do: Map.get(claims, p, 0)
            states = for p <- pois, do: Map.get(scene, p, air)

            unless taken == row["taken"] and states == row["states"] do
              raise "#{c["name"]} tick #{tick}: POIs vanilla #{inspect({row["taken"], row["states"]})} ours #{inspect({taken, states})}"
            end

            unless level_random == row["level_seed"] do
              raise "#{c["name"]} tick #{tick}: level random vanilla #{row["level_seed"]} ours #{level_random}"
            end

            checks =
              Enum.zip_with([entries, steps, row["mobs"]], fn [{id, entry}, step, expected] ->
                body = native_body.(entry.native, id)
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

                # A mind's running goals by registration index: a goal its
                # native module names by the vanilla goal registered there.
                goal_names = fn which ->
                  names = registered[body.type][which]

                  for {i, name} <- Map.fetch!(mind, which) do
                    if String.starts_with?(name, "Valimc."), do: Enum.at(names, i), else: name
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
                       behaviors: mind.brain.running,
                       activity: mind.brain.activity,
                       profession: body.data.profession,
                       home: global.(memory.(mind, :home)),
                       job_site: global.(memory.(mind, :job_site)),
                       potential_job_site: global.(memory.(mind, :potential_job_site)),
                       meeting_point: global.(memory.(mind, :meeting_point)),
                       walk_target: walk,
                       look_target: tracker.(memory.(mind, :look_target)),
                       sleeping: body.data.sleeping && Tuple.to_list(body.data.sleeping),
                       offers: Enum.map(body.data.offers || [], &[&1.uses, &1.demand]),
                       food_level: body.data.food_level,
                       inventory:
                         Enum.map(body.data.inventory, fn
                           nil -> nil
                           s -> [s.item_id, s.count, nil, nil]
                         end),
                       age: body.data.age,
                       gossip:
                         case body.data.gossips do
                           nil ->
                             []

                           {targets, _} ->
                             Enum.sort(
                               for {<<_::64, n::64>>, entries} <- targets,
                                   {type, value} <- entries,
                                   do: [n, Atom.to_string(type), value]
                             )
                         end,
                       restocks: body.data.restocks_today,
                       last_restock: body.data.last_restock,
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
                       offers: expected["offers"],
                       food_level: expected["food_level"],
                       inventory: expected["inventory"],
                       age: expected["age"],
                       gossip: Enum.sort(expected["gossip"]),
                       restocks: expected["restocks"],
                       last_restock: expected["last_restock"],
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
                      for {k, v} <- want,
                          got[k] != v,
                          not (id in changed and k in [:food_level, :inventory, :age]),
                          do: {k, v, got[k]}
                  end

                unless differ == [] do
                  raise "#{c["name"]} tick #{tick} mob #{id}: " <>
                          Enum.map_join(differ, "; ", fn {k, v, g} ->
                            "#{k} vanilla #{inspect(v)} ours #{inspect(g)}"
                          end)
                end

                1
              end)

            {entries, scene, level_random, count + Enum.sum(checks)}
        end)

      count
  end

# `updateSpecialPrices` under Hero of the Village (VMC-044b3) and with
# gossip about the player (VMC-044c1): a native villager with the restock
# scenes' offers starts trading with the player; its offers' special prices
# and first costs must equal vanilla's.
stock = hd(for(c <- cases, m <- c["mobs"], m["shop"], do: m["shop"]["offers"]))

for [amplifier, gossip_type, gossip_value, expected] <- fixtures["prices"] do
  {:ok, body} = Body.new("minecraft:villager")

  offers =
    for [a, n, b, nb, sell, ns, uses, max, demand, multiplier, xp] <- stock do
      %{
        buy: Valimc.Protocol.ItemStack.new(a, n),
        buy_b: b && Valimc.Protocol.ItemStack.new(b, nb),
        sell: Valimc.Protocol.ItemStack.new(sell, ns),
        uses: uses,
        max_uses: max,
        reward_exp: true,
        special_price: 0,
        demand: demand,
        price_multiplier: Valimc.Data.Float32.round(multiplier * 1.0),
        xp: xp
      }
    end

  # Gossip about the player (VMC-044c1), the oracle's fighter 77.
  gossips =
    if gossip_type,
      do: {[{<<1::64, 77::64>>, [{String.to_atom(gossip_type), gossip_value}]}], 1}

  body = %{
    body
    | data: %{body.data | offers: offers, profession: "minecraft:librarian", gossips: gossips}
  }

  section = Valimc.Entity.NativeMobs.new({0, 0})
  record = Store.body_record(body, <<5::128>>, {0.5, 64.0, 0.5})
  {:ok, _} = Native.mob_section_insert(section.ref, [{1, record}], false)
  {:ok, _} = Native.mob_section_merchant(section.ref, 1, {:start, <<1::64, 77::64>>, amplifier})
  {:ok, {view, _, _}} = Native.mob_section_merchant(section.ref, 1, :view)

  actual =
    for o <- view.offers,
        do: [o.special_price, Valimc.Menus.Merchant.cost_count(o)]

  unless actual == expected,
    do:
      raise(
        "Hero of the Village #{inspect(amplifier)}: #{inspect(actual)} != #{inspect(expected)}"
      )
end

IO.puts(
  "PASS: #{checked} villager ticks of #{length(cases)} scenes equal vanilla's (brains, schedules, POIs, beds, professions, motion, randoms, restocks); prices for #{length(fixtures["prices"])} Hero amplifiers and reputations"
)
