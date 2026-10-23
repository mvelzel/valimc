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
view = fn blocks ->
  scene = Map.new(blocks, fn [x, y, z, s] -> {{x, y, z}, s} end)
  {xs, zs} = {Enum.map(blocks, &Enum.at(&1, 0)), Enum.map(blocks, &Enum.at(&1, 2))}
  {x0, x1} = {min(-16, Enum.min(xs) - 4), max(16, Enum.max(xs) + 4)}
  {z0, z1} = {min(-16, Enum.min(zs) - 4), max(16, Enum.max(zs) + 4)}

  packed =
    for x <- x0..x1, y <- 56..80, z <- z0..z1, into: <<>> do
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
    yaw: 0.0,
    pitch: 0.0,
    eye: Valimc.Data.Float32.round(1.62),
    width: Valimc.Data.Float32.round(0.6),
    height: Valimc.Data.Float32.round(1.8),
    mode: mode,
    invulnerable: mode == :creative,
    alive: true,
    crouching: false,
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

  for {%{running: true}, {_, name, _, _, _}} <- Enum.zip(entries, registered), do: name
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
    "removed" => Enum.any?(step.effects, &match?({:convert, _}, &1)),
    "fire" => body.mob.living.fire_ticks,
    "health" => bits.(body.mob.living.health.value),
    "equipment" => equipment,
    "can_pick_up_loot" => body.mob.can_pick_up_loot,
    "converting" => Map.get(body.data, :converting)
  }
end

checked =
  for c <- cases, reduce: 0 do
    count ->
      {scene, kernel_view} = view.(c["blocks"])
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

      world = %AI.World{
        read: &Map.get(scene, &1, air),
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

          body = %{body | yaw: yaw, head_yaw: yaw, mob: %{body.mob | ai: mind}}
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

              # A hit with what it adds (VMC-043b: fire, an effect).
              hits =
                for {:attack, {:player, <<_::64, n::64>> = uuid}} <- step.effects do
                  extras =
                    Enum.find_value(step.effects, %{}, fn
                      {:attack_extra, {:player, ^uuid}, extras} -> extras
                      _ -> nil
                    end)

                  case extras do
                    %{effect: {effect, {duration, _, _, _, _}}} ->
                      {n, Valimc.Data.EffectTypes.name(effect), duration, extras[:ignite]}

                    _ ->
                      {n, nil, nil, extras[:ignite]}
                  end
                end

              sounds =
                for event <- Map.get(hurt_events, id, []) ++ step.events,
                    {name, volume, pitch} <- sound_of.(event),
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

              takes = for {:pickup, _, n} <- step.effects, do: n
              want_takes = for s <- expected["sounds"], s["take"] != nil, do: s["take"]

              level_events =
                for {:level_event, {cx, cy, cz}, type, data} <- step.effects,
                    do: [type, [cx, cy, cz], data]

              want_events =
                for s <- expected["sounds"],
                    s["event"] != nil,
                    do: [s["event"], s["at"], s["data"]]

              adds =
                for effect <- step.effects,
                    added = added.(effect),
                    added != nil,
                    do: added

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
                  if s["item"],
                    do: [s["add"], s["position"], s["velocity"], s["item"], s["count"]],
                    else: [s["add"], s["position"], s["velocity"], s["yaw"], s["pitch"]]
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
                takes: takes,
                level_events: level_events,
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
                takes: want_takes,
                level_events: want_events,
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
