# Vanilla mobs ticking with their own goals (MobAiOracle cases) against the
# owner's mob tick (VMC-041a): each scene's blocks as a supplied view, the
# same players standing still, the same hits between ticks, and the mobs'
# randoms seeded alike. Every tick, each mob's position, rotations (yaw,
# head, body, pitch), random seed, running goals and target goals, target,
# arms raised, path, hits on players and sounds must equal vanilla's.
alias Valimc.AI
alias Valimc.Entity.{Body, Combat, MobTicks}
alias Valimc.Living.DamageSource

[path] = System.argv()
Valimc.Data.BlockFacts.install!()
{fixtures, :ok, ""} = :json.decode(File.read!(path), :ok, %{null: nil})
cases = fixtures["cases"]
unless length(cases) >= 7, do: raise("Incomplete mob AI traces")

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
  Map.new(:json.decode(File.read!("priv/registry/ai_facts.json"))["sounds"], fn {n, id} ->
    {id, n}
  end)

# A scene as a supplied view: its blocks, and air around them.
view = fn blocks ->
  scene = Map.new(blocks, fn [x, y, z, s] -> {{x, y, z}, s} end)

  packed =
    for x <- -16..16, y <- 56..80, z <- -16..16, into: <<>> do
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
      offhand: nil
    }
  }
end

goal_names = fn body, which ->
  {goals, targets} = Valimc.AI.Mobs.registered(body.type)
  registered = if which == :goals, do: goals, else: targets
  entries = Tuple.to_list(if which == :goals, do: body.mob.ai.goals, else: body.mob.ai.targets)

  for {%{running: true}, {_, name, _, _, _}} <- Enum.zip(entries, registered), do: name
end

sound_name = fn
  id when is_integer(id) -> sound_names[id]
  name -> name
end

checked =
  for c <- cases, reduce: 0 do
    count ->
      {scene, kernel_view} = view.(c["blocks"])
      players = Enum.map(c["players"], player)

      world = %AI.World{
        read: &Map.get(scene, &1, air),
        players: players,
        difficulty: :normal
      }

      entries =
        for m <- c["mobs"] do
          yaw = float.(m["yaw"])
          {:ok, body} = Body.new(m["type"])
          {x, y, z} = vector.(m["position"])
          uuid = <<m["id"]::64, 0::64>>
          mind = AI.mind(m["type"], uuid, %{random: AI.Random.new(m["seed"])})
          mind = %{mind | body_yaw: yaw}
          body = %{body | yaw: yaw, head_yaw: yaw, mob: %{body.mob | ai: mind}}
          {m["id"], %{entity: %{uuid: uuid, x: x, y: y, z: z}, body: body, revision: 1}}
        end

      {_, count} =
        Enum.reduce(Enum.with_index(c["ticks"]), {entries, count}, fn {row, tick},
                                                                      {entries, count} ->
          world = %{world | time: 1001 + tick}

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

          steps = MobTicks.steps(kernel_view, entries, world, nil)

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
                  %{nodes: nodes, index: index} when index < length(nodes) ->
                    {nx, ny, nz} = Enum.at(nodes, index)
                    [nx, ny, nz, hex.(mind.navigation.speed)]

                  _ ->
                    nil
                end

              hits =
                for {:attack, {:player, <<_::64, n::64>>}} <- step.effects, do: n

              sounds =
                for {:sound, name, _, volume, pitch, _} <-
                      Map.get(hurt_events, id, []) ++ step.events,
                    do: {sound_name.(name), bits.(volume), bits.(pitch)}

              swings = for {:swing, :main_hand} <- step.events, do: "main_hand:whack:6"

              want_sounds =
                for s <- expected["sounds"],
                    s["sound"] != nil,
                    not String.ends_with?(s["sound"], ".step"),
                    do: {s["sound"], s["volume"], s["pitch"]}

              want_swings = for s <- expected["sounds"], s["swing"] != nil, do: s["swing"]
              want_hits = for h <- expected["hits"], do: h["player"]

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
                hits: hits
              }

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
                hits: want_hits
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

          {entries, count + Enum.sum(checks)}
        end)

      count
  end

IO.puts(
  "PASS: #{checked} mob AI ticks of #{length(cases)} scenes equal vanilla's (goals, targets, rotations, paths, randoms, hits, sounds)"
)
