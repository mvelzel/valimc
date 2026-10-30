# Vanilla path searches (MobAiOracle paths) against the native path search
# (VMC-041b, `valimc_core::path` through `Native.path_find`): each scene's
# blocks as a supplied view, the mob as vanilla's node evaluator read it
# (position, size, footing, step, fall limit, malus, door and fence
# abilities, random), the same targets, limits and region. Every search's
# nodes with their path types, target, whether it reaches it and the mob's
# random after it must equal vanilla's, for the walk, swim, fly and
# amphibious evaluators.
[path] = System.argv()
Valimc.Entity.MobFacts.install!()

# One search over `view`: `{nodes and types | nil, random}`, the nodes as
# `[[x, y, z, type]]` with the target and whether it reaches it.
find = fn view, request ->
  {:ok, [{found, random, _chunks}]} =
    Valimc.Native.dispatch(:path_find, request.max_visited, [view, [request]])

  found =
    with {nodes, target, reached} <- found do
      %{
        "nodes" =>
          for(
            <<x::signed-32, y::signed-32, z::signed-32, type <- nodes>>,
            do: [x, y, z, type]
          ),
        "target" => Tuple.to_list(target),
        "reached" => reached
      }
    end

  {found, random}
end

{fixtures, :ok, ""} = :json.decode(File.read!(path), :ok, %{null: nil})
cases = fixtures["cases"]
unless length(cases) >= 20, do: raise("Incomplete path fixtures")

double = fn hex ->
  <<v::float-64>> = Base.decode16!(hex, case: :lower)
  v
end

float = fn bits ->
  <<v::float-32>> = <<bits::signed-32>>
  v * 1.0
end

evaluators = %{
  "walk" => :walk,
  "swim" => {:swim, false},
  "swim_breaching" => {:swim, true},
  "fly" => :fly,
  "amphibious" => {:amphibious, false},
  "amphibious_shallow" => {:amphibious, true}
}

covered =
  for c <- cases, reduce: MapSet.new() do
    covered ->
      m = c["mob"]
      [x, y, z] = Enum.map(m["position"], double)
      [x0, y0, z0, x1, y1, z1] = c["region"]

      view =
        {:states,
         for(
           [bx, by, bz, s] <- c["blocks"],
           into: <<>>,
           do: <<bx::32-signed, by::32-signed, bz::32-signed, s::16>>
         )}

      request = %{
        evaluator: Map.fetch!(evaluators, c["evaluator"]),
        mob: %{
          position: {x, y, z},
          width: float.(m["width"]),
          height: float.(m["height"]),
          on_ground: m["on_ground"],
          in_water: m["in_water"],
          step: float.(m["step"]),
          max_fall: m["max_fall"],
          fall_distance: 0.0,
          malus: for(b <- m["malus"], into: <<>>, do: <<b::signed-32>>),
          can_pass_doors: m["can_pass_doors"],
          can_open_doors: m["can_open_doors"],
          can_float: m["can_float"],
          can_walk_over_fences: m["can_walk_over_fences"],
          random: m["random"]
        },
        targets: [List.to_tuple(c["target"])],
        max_path_length: float.(c["max_path_length"]),
        reach: c["reach"],
        max_visited: c["max_visited"],
        multiplier: 1.0,
        region: {{x0, y0, z0}, {x1, y1, z1}},
        min_y: -64,
        height: 384,
        sea_level: 63,
        border: nil
      }

      {got, random} = find.(view, request)

      unless got == c["path"] and random == c["random_after"] do
        raise "#{c["name"]}: vanilla #{inspect(c["path"])} random #{c["random_after"]}, " <>
                "ours #{inspect(got)} random #{random}"
      end

      MapSet.put(covered, c["evaluator"])
  end

missing = Map.keys(evaluators) -- MapSet.to_list(covered)
unless missing == [], do: raise("No path fixtures for #{inspect(missing)}")

IO.puts(
  "PASS: #{length(cases)} path searches equal vanilla's (walk, swim, fly, amphibious: nodes, types, reach, randoms)"
)
