# Differential check of pistons (VMC-048b: `valimc_core::rules::piston` on the live
# block-update engine) against PistonOracle's scenes: per game tick, the cells whose state
# changed, the sounds, the block events raised and those that ran, and every moving
# piston's block entity (moved state, direction, extending, source, progress and its old
# value, last tick). The scenes straddle chunk and section lines; the engine reads the four
# section stores as one group's. A note block's own sound is the owner's (it plays the
# events that ran), so vanilla's are left out of the sounds.
[scenes_file] = System.argv()
facts = JSON.decode!(File.read!(scenes_file))
rules = Valimc.World.BlockRules.native()
kinds = %{"set" => 0, "placed" => 1, "use" => 2}
ticks = 160

compare = fn scene ->
  cells = Map.new(scene["cells"], fn [x, y, z, s] -> {{x, y, z}, s} end)
  steps = scene["steps"]

  actions =
    for %{"t" => t, "actions" => actions} <- steps,
        [kind, x, y, z | values] <- actions do
      [a, b] = Enum.take(values ++ [0, 0], 2)
      {t, Map.fetch!(kinds, kind), {x, y, z}, a, b}
    end

  {:ok, ours} =
    Valimc.Native.piston_scene(
      rules,
      for({{x, y, z}, s} <- cells, do: {x, y, z, s}),
      actions,
      ticks,
      scene["seed"]
    )

  # `BlockPos` order: y, then z, then x.
  moving_order = fn rows -> Enum.sort_by(rows, fn [x, y, z | _] -> {y, z, x} end) end

  ours =
    Map.new(ours, fn {t, changes, sounds, raised, executed, moving} ->
      sounds = for {{x, y, z}, name, v, p, a} <- sounds, do: [x, y, z, name, v, p, a]
      raised = for {x, y, z, b, b0, b1} <- raised, do: [x, y, z, b, b0, b1]
      executed = for {x, y, z, b, b0, b1} <- executed, do: [x, y, z, b, b0, b1]

      moving =
        for {{x, y, z}, moved, d, {ext, src}, {p, po}, last} <- moving,
            do: [x, y, z, moved, d, if(ext, do: 1, else: 0), if(src, do: 1, else: 0), p, po, last]

      {t, {changes, sounds, raised, executed, moving_order.(moving)}}
    end)

  {vanilla, _} =
    Enum.map_reduce(steps, cells, fn step, cells ->
      after_tick =
        Enum.reduce(step["writes"], cells, fn [x, y, z, s], acc -> Map.put(acc, {x, y, z}, s) end)

      changes =
        for [x, y, z, _] <- Enum.uniq(step["writes"]),
            Map.get(after_tick, {x, y, z}, 0) != Map.get(cells, {x, y, z}, 0),
            uniq: true,
            do: {x, y, z, Map.fetch!(after_tick, {x, y, z})}

      sounds =
        for [x, y, z, n, v, p, a] <- step["sounds"],
            not String.starts_with?(n, "minecraft:block.note_block."),
            do: [x * 1.0, y * 1.0, z * 1.0, n, v, p, a]

      {{step["t"],
        {Enum.sort(changes), sounds, step["raised"], step["executed"],
         moving_order.(step["moving"])}}, after_tick}
    end)

  vanilla = Map.new(vanilla)
  empty = {[], [], [], [], []}

  0..(ticks - 1)
  |> Enum.find(fn t -> Map.get(vanilla, t, empty) != Map.get(ours, t, empty) end)
  |> case do
    nil -> :ok
    t -> {:mismatch, t, Map.get(vanilla, t, empty), Map.get(ours, t, empty)}
  end
end

results =
  facts["scenes"]
  |> Enum.with_index()
  |> Task.async_stream(fn {scene, i} -> {i, compare.(scene)} end,
    timeout: :infinity,
    ordered: true
  )
  |> Enum.map(fn {:ok, result} -> result end)

mismatches = for {i, {:mismatch, t, vanilla, ours}} <- results, do: {i, t, vanilla, ours}

unless mismatches == [] do
  [{scene, t, vanilla, ours} | _] = mismatches
  names = ~w(changes sounds raised executed moving)

  diffs =
    for {name, v, o} <- Enum.zip([names, Tuple.to_list(vanilla), Tuple.to_list(ours)]), v != o do
      "  #{name} vanilla: #{inspect(v, limit: 80)}\n  #{name} ours:    #{inspect(o, limit: 80)}"
    end

  actions =
    facts["scenes"]
    |> Enum.at(scene)
    |> Map.fetch!("steps")
    |> Enum.filter(&(&1["t"] <= t and &1["t"] >= t - 3))
    |> Enum.map(&{&1["t"], &1["actions"]})

  IO.puts("""
  #{length(mismatches)} of #{length(results)} scenes differ; first: scene #{scene}, tick #{t}
  #{Enum.join(diffs, "\n")}
    recent actions: #{inspect(actions, limit: 40)}\
  """)

  for {scene, t, _, _} <- tl(mismatches), do: IO.puts("  also scene #{scene}, tick #{t}")
  System.halt(1)
end

steps = Enum.flat_map(facts["scenes"], & &1["steps"])
count = fn key -> steps |> Enum.map(&length(&1[key])) |> Enum.sum() end

IO.puts(
  "PASS: #{length(results)} vanilla piston scenes of #{ticks} ticks (#{count.("writes")} writes, " <>
    "#{count.("executed")} block events run, #{count.("moving")} moving block states) push, pull, " <>
    "drop and land as the block-update engine does, across section lines"
)
