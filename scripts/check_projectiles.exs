# Vanilla projectile flights (ProjectileOracle) against the kernel's
# projectile tick (VMC-037o): arrows, snowballs, splash potions, small, large
# and dragon fireballs and eyes of ender over block scenes with zombies to
# hit. Each tick's position, velocity, rotation and water, ground and owner
# flags are compared bit for bit, and each hit (block, face, cell, point,
# inside and border flags, or the entity and point) as vanilla's `onHit`
# received it. An arrow that hits an entity is compared as it stopped there.
alias Valimc.Native

[path] = System.argv()
Valimc.Data.BlockFacts.install!()
fixtures = :json.decode(File.read!(path))
cases = fixtures["cases"]
unless length(cases) >= 150, do: raise("Incomplete projectile flights")

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

# The scene's cells around a tick's path, as a supplied view.
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

state_of = fn s ->
  {vector.(s["position"]), vector.(s["velocity"]), {float.(s["yaw"]), float.(s["pitch"])},
   {s["in_water"], Map.get(s, "in_ground", false), Map.get(s, "left_owner", true)}}
end

hit_of = fn
  %{"kind" => "block"} = h ->
    [x, y, z] = h["cell"]
    {:block, vector.(h["location"]), h["face"], {x, y, z}, h["inside"], h["border"]}

  %{"kind" => "entity"} = h ->
    {:entity, h["id"], vector.(h["location"])}
end

{flights, ticks, hits} =
  for c <- cases, reduce: {0, 0, 0} do
    {flights, ticks, hits} ->
      scene = Map.new(c["blocks"], fn [x, y, z, s] -> {{x, y, z}, s} end)
      parameter = double.(c["parameter"])

      kind =
        case c["kind"] do
          "arrow" -> {:arrow, parameter}
          "throwable" -> {:throwable, parameter}
          "hurting" -> {:hurting, parameter}
          "eye" -> {:eye, c["target"] && vector.(c["target"])}
        end

      size = {float.(c["width"]), float.(c["height"])}
      random = c["random"] |> Enum.map(float) |> List.to_tuple()

      targets =
        for t <- c["targets"] do
          {t["id"], vector.(t["position"]), t["box"] |> Enum.map(double) |> List.to_tuple()}
        end

      border = c["border"] && c["border"] |> Enum.map(double) |> List.to_tuple()
      {p, v, rotation, flags} = state_of.(c["start"])
      start = {p, v, rotation, 0, flags, -1}

      {_, count, hit_count} =
        Enum.reduce_while(Enum.with_index(c["ticks"]), {start, 0, 0}, fn {row, tick},
                                                                         {state, count, hit_count} ->
          {position, velocity, _, _, _, _} = state
          where = "#{c["name"]} (#{flights}) tick #{tick} from #{inspect(state)}"

          {:ok, [result]} =
            Native.physics_projectiles(
              window.(scene, position, velocity),
              [{state, kind, size, random, c["owner"]}],
              targets,
              border,
              false
            )

          {:ok, next, hit, _depths, _loosened} =
            case result do
              {:ok, _, _, _, _} = ok -> ok
              other -> raise("#{where}: #{inspect(other)}")
            end

          # A border deflects an arrow (vanilla's `deflect`, no `onHit`).
          {borders, expected} = Enum.split_with(row["hits"], &(&1["kind"] == "border"))

          if borders != [] and not match?({:block, _, _, _, _, true}, hit),
            do: raise("#{where}: hit #{inspect(hit)}, vanilla a border deflection")

          hit = if borders != [], do: nil, else: hit

          # An arrow that hits an entity stops there, before drag and gravity.
          {want, got_hit} =
            case {hit, expected} do
              {{:entities, [{id, at} | _]}, [%{"kind" => "entity", "at" => at_state}]} ->
                {state_of.(at_state), {:entity, id, at}}

              {hit, _} ->
                {state_of.(row), hit}
            end

          {np, nv, nr, _, nflags, _} = next

          for {field, got, vanilla} <- [
                {:position, np, elem(want, 0)},
                {:velocity, nv, elem(want, 1)},
                {:rotation, nr, elem(want, 2)},
                {:flags, nflags, elem(want, 3)}
              ],
              got != vanilla,
              do: raise("#{where}: #{field} #{inspect(got)}, vanilla #{inspect(vanilla)}")

          case expected do
            [] when got_hit == nil ->
              :ok

            [h] ->
              unless got_hit == hit_of.(h),
                do: raise("#{where}: hit #{inspect(got_hit)}, vanilla #{inspect(hit_of.(h))}")

            _ ->
              raise("#{where}: hit #{inspect(got_hit)}, vanilla #{inspect(expected)}")
          end

          hit_count = hit_count + length(expected) + length(borders)

          if row["removed"] or match?({:entity, _, _}, got_hit),
            do: {:halt, {next, count + 1, hit_count}},
            else: {:cont, {next, count + 1, hit_count}}
        end)

      {flights + 1, ticks + count, hits + hit_count}
  end

IO.puts(
  "PASS: #{flights} projectile flights, #{ticks} ticks and #{hits} hits equal vanilla's (arrows, thrown items, fireballs, eyes of ender)."
)
