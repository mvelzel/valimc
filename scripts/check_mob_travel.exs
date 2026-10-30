# Vanilla zombie ticks (MobTravelOracle) against native zombies through the
# kernel's mob tick (VMC-015i): each scene's blocks as a supplied view, the
# mobs driven toward the same targets, every tick's position, velocity,
# ground flag, fall distance and yaw compared bit for bit, landings with
# their fall damage, lava contact with vanilla's lava hurts, and the burning
# counter after the living rules around the move (vanilla records hurts
# without applying them, so health stays).
alias Valimc.Data.Float32
alias Valimc.Entity.{Mob, MobFacts, Store}
alias Valimc.Living.{FallDamage, Landing}

[path] = System.argv()
Valimc.Data.BlockFacts.install!()
MobFacts.install!()
fixtures = :json.decode(File.read!(path))
cases = fixtures["cases"]
unless length(cases) >= 19, do: raise("Incomplete mob travel traces")

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

vector = fn [x, y, z] -> {double.(x), double.(y), double.(z)} end

float = fn bits ->
  <<v::float-32>> = <<bits::32>>
  v * 1.0
end

air = Valimc.Data.Blocks.default_state("air")

# A scene as a supplied view: its blocks, and air around them.
view = fn blocks ->
  scene = Map.new(blocks, fn [x, y, z, s] -> {{x, y, z}, s} end)

  packed =
    for x <- -12..12, y <- 56..80, z <- -12..12, into: <<>> do
      <<x::signed-32, y::signed-32, z::signed-32, Map.get(scene, {x, y, z}, air)::16>>
    end

  {:states, packed}
end

{:ok, zombie} = Valimc.Entity.Body.new("minecraft:zombie")

checked =
  for c <- cases, reduce: 0 do
    count ->
      # Each mob's record and what its navigation asks of its move control
      # every tick (`MoveControl.setWantedPosition`).
      mobs =
        for {m, i} <- Enum.with_index(c["mobs"]) do
          yaw = float.(m["yaw"])
          body = %{zombie | yaw: yaw, head_yaw: yaw}
          record = Store.body_record(body, <<i + 1::128>>, vector.(m["position"]))
          target = if t = m["target"], do: {vector.(t), m["speed"] * 1.0}
          {record, target}
        end

      traced =
        Valimc.Native.mob_oracle_body_travel(view.(c["blocks"]), mobs, length(c["ticks"]))

      for {{row, results}, tick} <- Enum.with_index(Enum.zip(c["ticks"], traced)),
          {{expected, {t, fire}}, index} <- Enum.with_index(Enum.zip(row, results)),
          reduce: count do
        count ->
          m = t.mob
          where = "#{c["name"]} tick #{tick} mob #{index}"

          for {field, got, want} <- [
                {:position, m.position, vector.(expected["position"])},
                {:velocity, m.velocity, vector.(expected["velocity"])},
                {:on_ground, m.on_ground, expected["on_ground"]},
                {:fall_distance, m.fall_distance, double.(expected["fall_distance"])},
                {:yaw, Float32.round(m.yaw), float.(expected["yaw"])},
                {:horizontal_collision, m.horizontal_collision, expected["horizontal_collision"]}
              ],
              got != want,
              do: raise("#{where}: #{field} #{inspect(got)}, vanilla #{inspect(want)}")

          falls = for %{"kind" => "fall"} = e <- expected["events"], do: e

          case {t.landing, falls} do
            {nil, []} ->
              :ok

            {{state, distance}, [fall]} ->
              {:ok, call} = Landing.call(state, distance, false)

              {:ok, damage} =
                FallDamage.calculate(call.distance, call.multiplier, %FallDamage{
                  safe_distance: Mob.base("minecraft:zombie", %{}, "minecraft:safe_fall_distance")
                })

              unless call.distance == fall["distance"] and damage == fall["damage"],
                do:
                  raise("#{where}: landing #{inspect({call, damage})}, vanilla #{inspect(fall)}")

            other ->
              raise("#{where}: landing #{inspect(other)}")
          end

          hurts = for %{"kind" => "hurt", "amount" => 4.0} <- expected["events"], do: :lava

          # Lava hurts from its block's inside effect: a touched contact.
          lava = Enum.any?(t.fire_contacts.steps, &(:lava in &1))

          if hurts != [] != lava,
            do: raise("#{where}: lava contact #{lava}, vanilla hurts #{length(hurts)}")

          if fire != expected["fire"],
            do: raise("#{where}: fire ticks #{fire}, vanilla #{expected["fire"]}")

          count + 1
      end
  end

# Fire, soul fire and lava light the zombies; one burns out on stone and
# one is put out in water.
fires = for c <- cases, row <- c["ticks"], do: Enum.map(row, & &1["fire"])
lit = Enum.count(List.flatten(fires), &(&1 > 0))

outs =
  for c <- cases,
      {a, b} <- Enum.zip(c["ticks"], tl(c["ticks"])),
      {x, y} <- Enum.zip(a, b),
      x["fire"] > 0 and y["fire"] == 0,
      do: c["name"]

unless lit >= 200 and "fire_walk" in outs and "fire_water" in outs,
  do: raise("Burning coverage: #{lit} burning ticks, out in #{inspect(outs)}")

IO.puts(
  "PASS: #{checked} mob ticks over #{length(cases)} vanilla zombie traces equal bit for bit " <>
    "(position, velocity, ground, fall distance, yaw, landings and fall damage, lava contact, " <>
    "burning)."
)
