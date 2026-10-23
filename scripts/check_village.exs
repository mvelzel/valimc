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
alias Valimc.AI
alias Valimc.AI.Brains.Villager
alias Valimc.Entity.{Body, MobTicks}

[path] = System.argv()
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
          day: time
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
          mob = %{body.mob | ai: mind, no_ai: m["no_ai"]}
          body = %{body | yaw: yaw, head_yaw: yaw, mob: mob}
          {m["id"], %{entity: %{uuid: uuid, x: x, y: y, z: z}, body: body, revision: 1}}
        end

      {_, _, _, count} =
        Enum.reduce(Enum.with_index(c["ticks"]), {entries, scene0, AI.Random.new(7), count}, fn
          {row, tick}, {entries, scene, level_random, count} ->
            time = start + 1 + tick

            memories =
              for {_, %{body: %{mob: %{ai: %AI.Mind{brain: %{memories: m}}}}}} <- entries, do: m

            world = %{world0.(scene, time) | random: level_random, pois: AI.Pois.claims(memories)}
            kernel_view = {:states, packed.(scene)}
            {steps, world} = MobTicks.steps(kernel_view, entries, world, nil)

            unless length(steps) == length(entries),
              do: raise("#{c["name"]} tick #{tick}: a mob did not tick")

            entries =
              Enum.zip_with(entries, steps, fn {id, entry}, step ->
                {x, y, z} = step.position
                {id, %{entry | body: step.body, entity: %{entry.entity | x: x, y: y, z: z}}}
              end)

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
                for {_, %{body: %{mob: %{ai: %AI.Mind{brain: %{memories: m}}}}}} <- entries, do: m
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
                body = entry.body
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

                {got, want} =
                  if mind.brain do
                    self = %AI.Self{mind: mind}

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
                       behaviors: AI.Brain.running(self),
                       activity: AI.Brain.activity(self) |> then(&(&1 && Atom.to_string(&1))),
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

                if System.get_env("VILLAGE_DEBUG") == "#{c["name"]}:#{tick}",
                  do:
                    IO.inspect(
                      {tick,
                       for(
                         b <- Tuple.to_list(mind.brain.behaviors),
                         b.activity == :work and b.kind == AI.Behavior.Gate,
                         do:
                           for(
                             ch <- b.children,
                             do: {ch.weight, ch.behavior.running, Map.get(ch.behavior, :state)}
                           )
                       ), AI.Brain.running(%AI.Self{mind: mind}), memory.(mind, :walk_target),
                       memory.(mind, :look_target), mind.random, step.position},
                      label: "ours"
                    )

                # A mob held still (`NoAI`) is only scenery here: vanilla neither
                # moves nor thinks for it, and it stands where it was put.
                differ =
                  if body.mob.no_ai,
                    do: [],
                    else: for({k, v} <- want, got[k] != v, do: {k, v, got[k]})

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
  "PASS: #{checked} villager ticks of #{length(cases)} scenes equal vanilla's (brains, schedules, POIs, beds, professions, motion, randoms)"
)
