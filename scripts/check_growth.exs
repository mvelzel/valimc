# Differential check of growing plants (VMC-039a, `valimc_core::rules::growth` on the live
# block-update engine) against GrowthOracle's scenes: per game tick, the cells whose state
# changed, the level events (broken blocks) and each random tick's and bone meal's result
# (nothing, bone meal used, a tree grows). The scenes straddle chunk and section lines; the
# engine reads the four section stores as one group's.
[filename] = System.argv()
facts = JSON.decode!(File.read!(filename))
rules = Valimc.World.BlockRules.native()
kinds = %{"set" => 0, "random" => 1, "bone_meal" => 2}

compare = fn scene ->
  cells = Map.new(scene["cells"], fn [x, y, z, s] -> {{x, y, z}, s} end)

  # An action with no cell found nothing to act on, as ours would.
  actions =
    for %{"t" => t, "actions" => actions} <- scene["steps"],
        [kind, x, y, z | value] <- actions,
        do: {t, kinds[kind], x, y, z, List.first(value, 0)}

  {:ok, ours} =
    Valimc.Native.growth_scene(
      rules,
      for({{x, y, z}, s} <- cells, do: {x, y, z, s}),
      actions,
      400,
      scene["seed"],
      scene["sky"],
      scene["darken"],
      scene["rain"]
    )

  ours = Map.new(ours, fn {t, changes, events, results} -> {t, {changes, events, results}} end)

  # Vanilla's writes folded into per-tick changes against the scene's cells.
  {vanilla, _} =
    Enum.map_reduce(scene["steps"], cells, fn step, cells ->
      after_tick =
        Enum.reduce(step["writes"], cells, fn [x, y, z, s], acc -> Map.put(acc, {x, y, z}, s) end)

      changes =
        for [x, y, z, _] <- Enum.uniq(step["writes"]),
            Map.get(after_tick, {x, y, z}, 0) != Map.get(cells, {x, y, z}, 0),
            uniq: true,
            do: {x, y, z, Map.fetch!(after_tick, {x, y, z})}

      results =
        for {[kind | at], result} <- Enum.zip(step["actions"], step["results"]),
            kind != "set" and at != [],
            do: result

      {{step["t"],
        {Enum.sort(changes), Enum.sort(Enum.map(step["events"], &List.to_tuple/1)), results}},
       after_tick}
    end)

  vanilla = Map.new(vanilla)
  empty = {[], [], []}

  0..399
  |> Enum.find(fn t -> Map.get(vanilla, t, empty) != Map.get(ours, t, empty) end)
  |> case do
    nil -> :ok
    t -> {:mismatch, t, Map.get(vanilla, t, empty), Map.get(ours, t, empty)}
  end
end

failures =
  facts["scenes"]
  |> Enum.with_index()
  |> Enum.flat_map(fn {scene, i} ->
    case compare.(scene) do
      :ok -> []
      mismatch -> [{i, mismatch}]
    end
  end)

case failures do
  [] ->
    IO.puts("PASS: #{length(facts["scenes"])} growth scenes")

  [{i, {:mismatch, t, vanilla, ours}} | _] ->
    IO.puts("FAIL: #{length(failures)} scenes; scene #{i} first differs at tick #{t}")
    IO.inspect(vanilla, label: "vanilla", limit: :infinity)
    IO.inspect(ours, label: "ours", limit: :infinity)
    System.halt(1)
end
