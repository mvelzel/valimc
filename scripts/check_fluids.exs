# Differential check of water and lava (VMC-031a, `valimc_core::rules::fluid` run by the live
# block-update engine) against FluidOracle's scenes: per game tick, the cells whose state
# changed, the level events (fizzes, broken blocks) and each bucket's outcome. The scenes
# straddle chunk and section lines; the engine reads the four section stores as one group's.
[filename] = System.argv()
facts = JSON.decode!(File.read!(filename))
rules = Valimc.World.BlockRules.native()
alias Valimc.Blocks.Fluids

compare = fn scene ->
  cells = Map.new(scene["cells"], fn [x, y, z, s] -> {{x, y, z}, s} end)

  actions =
    for %{"t" => t, "actions" => actions} <- scene["steps"],
        action <- actions do
      case action do
        ["set", x, y, z, s] -> {t, 0, x, y, z, s}
        ["empty", x, y, z, fluid] -> {t, 1, x, y, z, fluid}
        ["pickup", x, y, z] -> {t, 2, x, y, z, 0}
      end
    end

  options =
    Fluids.options(scene["dimension"], scene["water_conversion"], scene["lava_conversion"])

  {:ok, ours} =
    Valimc.Native.fluid_scene(
      rules,
      for({{x, y, z}, s} <- cells, do: {x, y, z, s}),
      actions,
      320,
      scene["seed"],
      options
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
        Enum.zip_with(step["items"], Enum.filter(step["actions"], &(hd(&1) != "set")), fn
          item, ["pickup" | _] -> item
          done, ["empty" | _] -> done
        end)

      {{step["t"],
        {Enum.sort(changes), Enum.sort(Enum.map(step["events"], &List.to_tuple/1)), results}},
       after_tick}
    end)

  vanilla = Map.new(vanilla, fn {t, v} -> {t, v} end)

  # Pickup items are compared by name.
  ours =
    Map.new(ours, fn {t, {changes, events, results}} ->
      kinds =
        for %{"t" => ^t, "actions" => a} <- scene["steps"],
            action <- a,
            hd(action) != "set",
            do: hd(action)

      results =
        Enum.zip_with(results, kinds, fn
          0, "pickup" -> ""
          r, "pickup" -> Fluids.pickup_item(r)
          r, "empty" -> if(r == 0, do: 0, else: 1)
        end)

      {t, {changes, events, results}}
    end)

  empty = {[], [], []}

  0..319
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
  {vc, ve, vr} = vanilla
  {oc, oe, or_} = ours

  IO.puts("""
  #{length(mismatches)} of #{length(results)} scenes differ; first: scene #{scene}, tick #{t}
    changes only vanilla: #{inspect(vc -- oc, limit: 60)}
    changes only ours:    #{inspect(oc -- vc, limit: 60)}
    events vanilla: #{inspect(ve, limit: 30)}
    events ours:    #{inspect(oe, limit: 30)}
    results vanilla: #{inspect(vr)} ours: #{inspect(or_)}\
  """)

  for {scene, t, _, _} <- tl(mismatches), do: IO.puts("  also scene #{scene}, tick #{t}")
  System.halt(1)
end

writes =
  facts["scenes"] |> Enum.flat_map(& &1["steps"]) |> Enum.map(&length(&1["writes"])) |> Enum.sum()

IO.puts(
  "PASS: #{length(results)} vanilla fluid scenes of 320 ticks (#{writes} writes) flow, mix, " <>
    "waterlog and take buckets as the block-update engine does, across section lines."
)
