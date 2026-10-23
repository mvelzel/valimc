# Vanilla shulker bullets (ShulkerBulletOracle) against ours (VMC-043e):
# each made as a shulker makes it (its first direction, steps and deltas
# from its seeded random), then flown tick by tick through the projectile
# kernel with `Valimc.Entity.ShulkerBullet` steering and turning it over the
# same scene, toward the same zombie (one lost on the way). Every tick's
# position, motion, rotation, owner and water flags, direction, steps,
# deltas, random and hit must equal vanilla's (whether it left its shooter
# as the next tick reads it).
alias Valimc.Entity.{Projectile, ShulkerBullet}

[path] = System.argv()
Valimc.Data.BlockFacts.install!()
fixtures = :json.decode(File.read!(path))
cases = fixtures["cases"]
unless length(cases) >= 15, do: raise("Incomplete shulker bullet flights")

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

window = fn scene, {x, y, z}, {vx, vy, vz} ->
  lo = fn a, d -> floor(min(a, a + d)) - 4 end
  hi = fn a, d -> floor(max(a, a + d)) + 4 end

  packed =
    for cx <- lo.(x, vx)..hi.(x, vx),
        cy <- lo.(y, vy)..hi.(y, vy),
        cz <- lo.(z, vz)..hi.(z, vz),
        into: <<>> do
      <<cx::signed-32, cy::signed-32, cz::signed-32, Map.get(scene, {cx, cy, cz}, air)::16>>
    end

  {:states, packed}
end

ours = fn body, position ->
  d = body.data

  %{
    position: position,
    velocity: body.velocity,
    rotation: {body.yaw, body.pitch},
    in_water: d.in_water,
    left_owner: d.left_owner,
    direction: d.direction || -1,
    steps: d.steps,
    deltas: d.deltas,
    seed: d.random
  }
end

theirs = fn s ->
  %{
    position: vector.(s["position"]),
    velocity: vector.(s["velocity"]),
    rotation: {float.(s["yaw"]), float.(s["pitch"])},
    in_water: s["in_water"],
    left_owner: s["left_owner"],
    direction: s["direction"],
    steps: s["steps"],
    deltas: vector.(s["deltas"]),
    seed: s["seed"]
  }
end

hit_of = fn
  %{"kind" => "block"} = h ->
    [x, y, z] = h["cell"]
    {:block, vector.(h["location"]), h["face"], {x, y, z}, h["inside"], h["border"]}

  %{"kind" => "entity"} = h ->
    {:entity, h["id"], vector.(h["location"])}
end

compare = fn where, got, want ->
  differ =
    for {k, v} <- want, got[k] != v, do: "#{k} vanilla #{inspect(v)} ours #{inspect(got[k])}"

  unless differ == [], do: raise("#{where}: " <> Enum.join(differ, "; "))
end

{flights, ticks, hits} =
  for c <- cases, reduce: {0, 0, 0} do
    {flights, ticks, hits} ->
      scene = Map.new(c["blocks"], fn [x, y, z, s] -> {{x, y, z}, s} end)
      read = &Map.get(scene, &1, air)
      t = c["target"]
      box = t["box"] |> Enum.map(double) |> List.to_tuple()
      uuid = <<t["id"]::128>>

      target = %{
        uuid: uuid,
        ref: {:mob, uuid},
        position: vector.(t["position"]),
        box: box,
        alive: true,
        spectator: false
      }

      owner = %{uuid: <<0::128>>, id: c["owner"], player: false, type: "minecraft:shulker"}
      from = vector.(c["from"])
      axis = elem({0, 1, 2}, c["axis"])

      body =
        ShulkerBullet.new(owner, from, target, axis, nil, read, Valimc.AI.Random.new(c["seed"]))

      where = "#{c["name"]} seed #{c["seed"]}"
      compare.("#{where} start", ours.(body, from), Map.delete(theirs.(c["start"]), :left_owner))

      {_, _, count, hit_count} =
        Enum.reduce_while(Enum.with_index(c["ticks"]), {body, from, 0, 0}, fn {row, tick},
                                                                              {body, position,
                                                                               count, hit_count} ->
          present = if c["lose"] >= 0 and tick >= c["lose"], do: nil, else: target
          body = ShulkerBullet.prepare(body, present)
          # The shooter too, which it does not hit before it has left it.
          shooter =
            {c["owner"], vector.(c["owner_position"]),
             c["owner_box"] |> Enum.map(double) |> List.to_tuple()}

          targets = [shooter | if(present, do: [{t["id"], target.position, box}], else: [])]

          {:ok, [result]} =
            Valimc.Native.physics_projectiles(
              window.(scene, position, body.velocity),
              [Projectile.input(body, position, {0.0, 0.0, 0.0})],
              targets,
              nil,
              false
            )

          {:ok, state, hit, _, _} = result
          {next, _, _, _, _, _} = state
          body = Projectile.advance(body, state)
          # Vanilla turns it even on the tick it hits (and is gone).
          body = ShulkerBullet.turn(body, next, present, read)
          where = "#{where} tick #{tick}"
          # The kernel decides whether it left its shooter after the move,
          # for the next tick's hits; vanilla before the next tick's move.
          following = Enum.at(c["ticks"], tick + 1)
          want = theirs.(row)

          want =
            if following,
              do: %{want | left_owner: following["left_owner"]},
              else: Map.delete(want, :left_owner)

          compare.(where, ours.(body, next), want)

          case row["hits"] do
            [] when hit == nil ->
              :ok

            [h] ->
              unless hit == hit_of.(h),
                do: raise("#{where}: hit #{inspect(hit)}, vanilla #{inspect(h)}")

            other ->
              raise("#{where}: hit #{inspect(hit)}, vanilla #{inspect(other)}")
          end

          hit_count = hit_count + length(row["hits"])

          if row["removed"],
            do: {:halt, {body, next, count + 1, hit_count}},
            else: {:cont, {body, next, count + 1, hit_count}}
        end)

      {flights + 1, ticks + count, hits + hit_count}
  end

IO.puts(
  "PASS: #{flights} shulker bullet flights, #{ticks} ticks and #{hits} hits equal vanilla's (directions, steering, turns, randoms)."
)
