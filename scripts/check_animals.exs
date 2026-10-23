# Vanilla farm animals (AnimalOracle cases) against the owner's mob tick
# (VMC-043c), as check_mob_ai.exs runs mobs: each scene's blocks as a
# supplied view, the same players standing still, randoms seeded alike, and
# between ticks what the scene does to the animals (falling in love, a baby
# fed). Every tick, each animal's position, motion, rotations, random,
# running goals, age, love and own data (wool, type, variant, egg time, a
# rabbit's hop), its sounds and entity events must equal vanilla's, and the
# blocks they ate, the children born (seeded as the oracle seeds them) and
# breeding's orbs too.
alias Valimc.AI
alias Valimc.Entity.{Animal, Body, MobTicks}

[path] = System.argv()
Valimc.Data.BlockFacts.install!()
{fixtures, :ok, ""} = :json.decode(File.read!(path), :ok, %{null: nil})
cases = fixtures["cases"]
unless length(cases) >= 12, do: raise("Incomplete animal traces")

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
plains = "minecraft:plains"

sound_names =
  Map.new(
    Map.merge(
      :json.decode(File.read!("priv/registry/ai_facts.json"))["sounds"],
      :json.decode(File.read!("priv/registry/animal_facts.json"))["sounds"]
    ),
    fn {n, id} -> {id, n} end
  )

sound_name = fn
  id when is_integer(id) -> sound_names[id]
  name -> name
end

packed = fn scene ->
  for x <- -16..16, y <- 56..80, z <- -16..16, into: <<>> do
    <<x::signed-32, y::signed-32, z::signed-32, Map.get(scene, {x, y, z}, air)::16>>
  end
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
      offhand: nil
    }
  }
end

goal_names = fn body ->
  {goals, _} = Valimc.AI.Mobs.registered(body.type)

  for {%{running: true}, {_, name, _, _, _}} <- Enum.zip(Tuple.to_list(body.mob.ai.goals), goals),
      do: name
end

# The oracle's data of an animal: its type's own fields.
put_data = fn body, data ->
  own =
    for {key, value} <- data,
        key not in ["age", "in_love", "jumping"],
        into: %{} do
      case {body.type, key} do
        {"minecraft:mooshroom", "type"} -> {:type, value}
        {_, "variant"} -> {:variant, value}
        {_, key} -> {String.to_atom(key), value}
      end
    end

  %{
    body
    | data: Map.merge(body.data, Map.merge(own, %{age: data["age"], in_love: data["in_love"]}))
  }
end

our_data = fn body ->
  data = body.data
  base = %{"age" => data.age, "in_love" => data.in_love}

  own =
    case body.type do
      "minecraft:sheep" -> %{"color" => data.color, "sheared" => data.sheared}
      "minecraft:rabbit" -> %{"type" => data.type, "jumping" => body.mob.motion.hop.jumping}
      "minecraft:mooshroom" -> %{"type" => data.type}
      "minecraft:chicken" -> %{"egg_time" => data.egg_time, "variant" => data.variant}
      _ -> %{"variant" => data.variant}
    end

  Map.merge(base, own)
end

entry = fn id, type, uuid_n, position, {yaw, head, body_yaw}, seed, data, no_ai ->
  {:ok, body} = Body.new(type)
  body = put_data.(body, data)
  body = %{body | mob: %{body.mob | no_ai: no_ai}}
  uuid = <<uuid_n::64, 0::64>>
  mind = AI.mind(type, uuid, %{random: AI.Random.new(seed)})
  mind = %{mind | random: AI.Random.new(seed), body_yaw: body_yaw}
  body = %{body | yaw: yaw, head_yaw: head, mob: %{body.mob | ai: mind}}
  {x, y, z} = position
  {id, %{entity: %{uuid: uuid, x: x, y: y, z: z}, body: body, revision: 1}}
end

grass_block = Valimc.Data.Blocks.default_state("grass_block")
dirt = Valimc.Data.Blocks.default_state("dirt")

checked =
  for c <- cases, reduce: 0 do
    count ->
      scene0 = Map.new(c["blocks"], fn [x, y, z, s] -> {{x, y, z}, s} end)
      players = Enum.map(c["players"], player)

      entries =
        for m <- c["mobs"] do
          entry.(
            m["id"],
            m["type"],
            m["id"],
            vector.(m["position"]),
            {float.(m["yaw"]), float.(m["yaw"]), float.(m["yaw"])},
            m["seed"],
            m["data"],
            m["no_ai"]
          )
        end

      born_by_tick = Enum.group_by(c["born"], & &1["tick"])

      {_, _, _, count} =
        Enum.reduce(
          Enum.with_index(c["ticks"]),
          {entries, {scene0, {:states, packed.(scene0)}}, AI.Random.new(7), count},
          fn {row, tick}, {entries, {scene, kernel_view}, level, count} ->
            world = %AI.World{
              read: &Map.get(scene, &1, air),
              search: fn request ->
                [result] = AI.Paths.find(kernel_view, [request])
                result
              end,
              players: players,
              random: level,
              difficulty: :normal,
              time: 1001 + tick,
              biome: fn _ -> plains end
            }

            # What the scene does before the tick: love, a baby fed.
            {entries, acted} =
              Enum.reduce(c["acts"], {entries, %{}}, fn a, {entries, acted} ->
                if a["tick"] == tick do
                  {id, e} = Enum.at(entries, a["mob"])

                  {body, events} =
                    case a["what"] do
                      "love" -> Animal.fall_in_love(e.body, nil)
                      "feed" -> {Animal.feed_baby(e.body), []}
                    end

                  {List.replace_at(entries, a["mob"], {id, %{e | body: body}}),
                   Map.put(acted, id, events)}
                else
                  {entries, acted}
                end
              end)

            {steps, world} = MobTicks.steps(kernel_view, entries, world, nil)

            unless length(steps) == length(entries),
              do: raise("#{c["name"]} tick #{tick}: a mob did not tick")

            entries =
              Enum.zip_with(entries, steps, fn {id, e}, step ->
                {x, y, z} = step.position
                {id, %{e | body: step.body, entity: %{e.entity | x: x, y: y, z: z}}}
              end)

            checks =
              Enum.zip_with([entries, steps, row["mobs"]], fn [{id, e}, step, expected] ->
                body = e.body
                mind = body.mob.ai
                {x, y, z} = step.position

                sounds =
                  for event <- Map.get(acted, id, []) ++ step.events,
                      out <-
                        (case event do
                           {:sound, name, _, volume, pitch, _} ->
                             [{sound_name.(name), bits.(volume), bits.(pitch)}]

                           {:event, n} ->
                             [{:event, n}]

                           _ ->
                             []
                         end),
                      do: out

                want_sounds =
                  for s <- expected["sounds"],
                      out <-
                        (cond do
                           s["sound"] != nil and not String.ends_with?(s["sound"], ".step") ->
                             [{s["sound"], s["volume"], s["pitch"]}]

                           s["event"] != nil ->
                             [{:event, s["event"]}]

                           true ->
                             []
                         end),
                      do: out

                got = %{
                  id: id,
                  position: Enum.map(Tuple.to_list({x, y, z}), hex),
                  velocity: Enum.map(Tuple.to_list(body.velocity), hex),
                  on_ground: body.on_ground,
                  yaw: bits.(body.yaw),
                  head: bits.(body.head_yaw),
                  body: bits.(mind.body_yaw),
                  pitch: bits.(body.pitch),
                  seed: mind.random,
                  goals: Enum.join(goal_names.(body), ","),
                  data: our_data.(body),
                  sounds: sounds
                }

                want = %{
                  id: expected["id"],
                  position: expected["position"],
                  velocity: expected["velocity"],
                  on_ground: expected["on_ground"],
                  yaw: expected["yaw"],
                  head: expected["head"],
                  body: expected["body"],
                  pitch: expected["pitch"],
                  seed: expected["seed"],
                  goals: expected["goals"],
                  data: expected["data"],
                  sounds: want_sounds
                }

                differ = for {k, v} <- want, got[k] != v, do: {k, v, got[k]}

                unless differ == [] do
                  raise "#{c["name"]} tick #{tick} mob #{id}: " <>
                          Enum.map_join(differ, "; ", fn {k, v, g} ->
                            "#{k} vanilla #{inspect(v)} ours #{inspect(g)}"
                          end)
                end

                1
              end)

            # The blocks they ate.
            {scene, edits} =
              for step <- steps, effect <- step.effects, reduce: {scene, []} do
                {scene, edits} ->
                  case effect do
                    {:eat_block, {x, y, z} = cell, :dirt} ->
                      {Map.put(scene, cell, dirt),
                       edits ++
                         [
                           %{"at" => [x, y, z], "event" => 2001, "data" => grass_block},
                           %{"at" => [x, y, z], "state" => dirt}
                         ]}

                    {:eat_block, {x, y, z} = cell, :destroy} ->
                      {Map.put(scene, cell, air), edits ++ [%{"at" => [x, y, z], "state" => air}]}

                    _ ->
                      {scene, edits}
                  end
              end

            unless edits == row["edits"],
              do:
                raise(
                  "#{c["name"]} tick #{tick}: edits vanilla #{inspect(row["edits"])} ours #{inspect(edits)}"
                )

            unless world.random == row["level_seed"],
              do:
                raise(
                  "#{c["name"]} tick #{tick}: level random vanilla #{row["level_seed"]} ours #{world.random}"
                )

            # Children and orbs, where the parent stood.
            made =
              for step <- steps,
                  effect <- step.effects,
                  out <- [effect],
                  match?({:offspring, _, _, _}, out) or match?({:orb, _, _}, out),
                  do: out

            # Vanilla adds a breeding's orb before its child.
            made = Enum.sort_by(made, &(elem(&1, 0) != :orb))
            wanted = Map.get(born_by_tick, tick, [])

            unless length(made) == length(wanted),
              do:
                raise(
                  "#{c["name"]} tick #{tick}: births vanilla #{inspect(wanted)} ours #{inspect(made)}"
                )

            entries =
              Enum.zip(made, wanted)
              |> Enum.reduce(entries, fn
                {{:orb, value, at}, w}, entries ->
                  unless value == w["orb"] and Enum.map(Tuple.to_list(at), hex) == w["position"],
                    do:
                      raise(
                        "#{c["name"]} tick #{tick}: orb vanilla #{inspect(w)} ours #{inspect({value, at})}"
                      )

                  entries

                {{:offspring, type, data, at}, w}, entries ->
                  {:ok, child} = Body.new(type)
                  ours = our_data.(%{child | data: data})
                  theirs = Map.drop(w["data"], ["egg_time"])

                  unless type == w["type"] and Map.drop(ours, ["egg_time"]) == theirs and
                           Enum.map(Tuple.to_list(at), hex) == w["position"],
                         do:
                           raise(
                             "#{c["name"]} tick #{tick}: child vanilla #{inspect(w)} ours #{inspect({type, ours, at})}"
                           )

                  # The child's own draws (a chick's egg time) are the oracle's.
                  entries ++
                    [
                      entry.(
                        w["id"],
                        type,
                        w["id"],
                        at,
                        {float.(w["yaw"]), float.(w["head"]), float.(w["body"])},
                        w["seed"],
                        Map.merge(Map.new(data, fn {k, v} -> {to_string(k), v} end), w["data"]),
                        false
                      )
                    ]
              end)

            # The view packs again only after an animal ate a block.
            view = if edits == [], do: kernel_view, else: {:states, packed.(scene)}
            {entries, {scene, view}, world.random, count + Enum.sum(checks)}
          end
        )

      count
  end

# Breedings on their own: the child's data, the orb, the parents after, and
# the parent's and the level's randoms.
bred =
  for {b, n} <- Enum.with_index(fixtures["breeding"]), reduce: 0 do
    count ->
      type = b["type"]
      {:ok, body} = Body.new(type)
      parent = put_data.(body, b["parent"])
      partner = put_data.(body, b["partner"])

      self = %AI.Self{
        id: 1,
        uuid: <<1::128>>,
        type: type,
        x: 0.5,
        y: 64.0,
        z: 0.5,
        mob: parent.mob,
        mind: %AI.Mind{random: AI.Random.new(b["seed"])},
        data: parent.data,
        world: %AI.World{random: AI.Random.new(b["level_seed"]), biome: fn _ -> plains end}
      }

      # The oracle seeded the randoms directly: their states are the seeds.
      self = %{
        self
        | mind: %{self.mind | random: b["seed"]},
          world: %{self.world | random: b["level_seed"]}
      }

      sensed = %{kind: :mob, uuid: <<2::128>>, data: partner.data}
      self = Animal.breed(self, sensed)

      [{:offspring, ^type, child, _}] = for {:offspring, _, _, _} = o <- self.effects, do: o
      [{:orb, orb, _}] = for {:orb, _, _} = o <- self.effects, do: o
      partner_after = %{partner | data: Animal.bred(partner.data)}

      got = %{
        child: Map.drop(our_data.(%{body | data: child}), ["egg_time"]),
        orb: orb,
        parent: our_data.(%{parent | data: self.data}),
        partner: our_data.(partner_after),
        seed: self.mind.random,
        level_seed: self.world.random
      }

      want = %{
        child: Map.drop(b["child"], ["egg_time"]),
        orb: b["orb"],
        parent: b["parent_after"],
        partner: b["partner_after"],
        seed: b["seed_after"],
        level_seed: b["level_seed_after"]
      }

      differ = for {k, v} <- want, got[k] != v, do: {k, v, got[k]}

      unless differ == [],
        do: raise("breeding #{n} (#{type}): #{inspect(differ)}")

      count + 1
  end

IO.puts("PASS: #{bred} breedings equal vanilla's (children, orbs, parents, randoms)")

# `finalizeSpawn` of fresh animals by biome: their variants, sound variants,
# colours and types, the follow range bonus, handedness and both randoms.
spawned =
  for {c, n} <- Enum.with_index(fixtures["spawns"]), reduce: 0 do
    count ->
      type = c["type"]
      {:ok, body} = Body.new(type)
      {width, height, eye} = Body.dimensions(body)
      biome = c["biome"]

      self =
        AI.Spawn.finalize(%AI.Self{
          id: 1,
          uuid: <<1::128>>,
          type: type,
          x: 0.5,
          y: 64.0,
          z: 0.5,
          yaw: 0.0,
          pitch: 0.0,
          head: 0.0,
          on_ground: true,
          mob: %{body.mob | finalize: :natural},
          mind: %AI.Mind{random: AI.Random.new(c["mob_seed"])},
          facts: AI.Facts.mob(type),
          width: width,
          height: height,
          eye: eye,
          data: body.data,
          world: %AI.World{random: AI.Random.new(c["level_seed"]), biome: fn _ -> biome end}
        })

      bonus =
        case get_in(self.mob.attributes, ["minecraft:follow_range", :modifiers]) do
          [{_, amount, _}] -> hex.(amount)
          _ -> nil
        end

      got = %{
        data:
          Map.drop(our_data.(%{body | data: self.data, mob: self.mob}), ["egg_time", "jumping"]),
        sound_variant: Map.get(self.data, :sound_variant),
        follow_bonus: bonus,
        left_handed: self.mob.left_handed,
        level_seed: self.world.random,
        mob_seed: self.mind.random
      }

      want = %{
        data: Map.drop(c["data"], ["egg_time", "jumping"]),
        sound_variant: c["sound_variant"],
        follow_bonus: c["follow_bonus"],
        left_handed: c["left_handed"],
        level_seed: c["level_seed_after"],
        mob_seed: c["mob_seed_after"]
      }

      differ = for {k, v} <- want, got[k] != v, do: {k, v, got[k]}
      unless differ == [], do: raise("spawn #{n} (#{type} in #{biome}): #{inspect(differ)}")
      count + 1
  end

IO.puts("PASS: #{spawned} spawns equal vanilla's (variants, colours, types, bonus, randoms)")

# The animals' loot tables with the same animal, seed and origin: deaths,
# shearing and laying (`Valimc.Blocks.Loot.entity_drops/4` reading the
# animal's properties).
dropped =
  for {c, n} <- Enum.with_index(fixtures["drops"]), reduce: 0 do
    count ->
      {:ok, body} = Body.new(c["type"])
      body = put_data.(body, c["data"])
      {x, y, z} = vector.(c["position"])

      {:ok, stacks} =
        Valimc.Blocks.Loot.entity_drops(c["table"], c["seed"], {x, y, z}, %{
          on_fire: c["on_fire"],
          properties: Animal.properties(body)
        })

      got = for s <- stacks, do: {Valimc.Protocol.ItemTypes.item(s.item_id)["name"], s.count}
      want = for i <- c["items"], do: {i["id"], i["count"] || 1}

      unless got == want,
        do:
          raise(
            "drops #{n} (#{c["table"]}, #{inspect(c["data"])}): vanilla #{inspect(want)} ours #{inspect(got)}"
          )

      count + 1
  end

IO.puts("PASS: #{dropped} drops equal vanilla's (deaths, shearing, laying)")

IO.puts(
  "PASS: #{checked} animal ticks of #{length(cases)} scenes equal vanilla's (goals, rotations, randoms, age, love, wool, hops, sounds, events, grazing, births)"
)
