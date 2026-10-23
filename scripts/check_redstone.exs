# Differential check of redstone (VMC-047a, VMC-048a: `valimc_core::rules::power` and
# `components` on the live block-update engine) against RedstoneOracle's circuit scenes: per
# game tick, the cells whose state changed, the level events, the sounds, the block events,
# the primed TNT, the uses' results and the comparators whose output changed. The scenes
# straddle chunk and section lines; the engine reads the four section stores as one group's.
# A container's new contents give the signal ValiMC computes from them
# (`Valimc.Blocks.Redstone.container_signal/2`), which must be vanilla's. With a day file,
# also the day cycle daylight detectors read (`skyDarken` and the sun angle) at every sample.
[scenes_file | rest] = System.argv()
facts = JSON.decode!(File.read!(scenes_file))
rules = Valimc.World.BlockRules.native()

kinds = %{
  "set" => 0,
  "use" => 1,
  "placed" => 2,
  "page" => 3,
  "hit" => 4,
  "disarm" => 5,
  "fill" => 6
}

# A fill's signal from its slots, as the owner computes it; vanilla's must match.
fill_signal = fn
  _at, -1, _slots, _size ->
    -1

  at, signal, slots, size ->
    stacks = for [_, item, count] <- slots, do: {item, count}
    ours = Valimc.Blocks.Redstone.container_signal(stacks, size)

    if ours != signal,
      do:
        raise(
          "container signal at #{inspect(at)}: vanilla #{signal}, ours #{ours} for #{inspect(slots)}"
        )

    signal
end

compare = fn scene ->
  cells = Map.new(scene["cells"], fn [x, y, z, s] -> {{x, y, z}, s} end)
  steps = scene["steps"]

  actions =
    for %{"t" => t, "actions" => actions} <- steps,
        [kind, x, y, z | values] <- actions,
        Map.has_key?(kinds, kind) do
      case {kind, values} do
        {"fill", [signal, slots, size]} ->
          {t, 6, {x, y, z}, fill_signal.({x, y, z}, signal, slots, size), 0}

        _ ->
          [a, b] = Enum.take(values ++ [0, 0], 2)
          {t, kinds[kind], {x, y, z}, a, b}
      end
    end

  entities =
    for %{"t" => t, "actions" => actions} <- steps,
        ["entity", _, _, _, x0, y0, z0, x1, y1, z1, kind, until] <- actions,
        do: {t, {x0 * 1.0, y0 * 1.0, z0 * 1.0}, {x1 * 1.0, y1 * 1.0, z1 * 1.0}, kind, until}

  days = for %{"t" => t, "day" => [darken, angle]} <- steps, do: {t, darken, angle}

  {:ok, ours} =
    Valimc.Native.redstone_scene(
      rules,
      for({{x, y, z}, s} <- cells, do: {x, y, z, s}),
      actions,
      entities,
      days,
      200,
      scene["seed"],
      scene["tnt_explodes"]
    )

  ours =
    Map.new(ours, fn {t, changes, events, sounds, {block_events, primed, results, outputs}} ->
      sounds = for {{x, y, z}, name, v, p, a} <- sounds, do: [x, y, z, name, v, p, a]
      block_events = for {x, y, z, b, b0, b1} <- block_events, do: [x, y, z, b, b0, b1]
      primed = for {x, y, z} <- primed, do: [x, y, z]
      outputs = for {x, y, z, o} <- outputs, do: [x, y, z, o]
      {t, {changes, events, sounds, block_events, primed, results, outputs}}
    end)

  # Vanilla's writes folded into per-tick changes against the scene's cells.
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
        for [x, y, z, n, v, p, a] <- step["sounds"], do: [x * 1.0, y * 1.0, z * 1.0, n, v, p, a]

      {{step["t"],
        {Enum.sort(changes), Enum.sort(Enum.map(step["events"], &List.to_tuple/1)), sounds,
         step["block_events"], step["primed"], step["results"], Map.get(step, "outputs", [])}},
       after_tick}
    end)

  vanilla = Map.new(vanilla)
  empty = {[], [], [], [], [], [], []}

  0..199
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
  names = ~w(changes events sounds block_events primed results outputs)

  diffs =
    for {name, v, o} <- Enum.zip([names, Tuple.to_list(vanilla), Tuple.to_list(ours)]), v != o do
      "  #{name} vanilla: #{inspect(v, limit: 60)}\n  #{name} ours:    #{inspect(o, limit: 60)}"
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

writes =
  facts["scenes"] |> Enum.flat_map(& &1["steps"]) |> Enum.map(&length(&1["writes"])) |> Enum.sum()

day =
  case rest do
    [day_file] ->
      samples = JSON.decode!(File.read!(day_file))["samples"]

      {:ok, ours} =
        Valimc.Native.redstone_day(rules, for([t, r, th | _] <- samples, do: {t, r, th}))

      bad =
        Enum.zip(samples, ours)
        |> Enum.reject(fn {[_, _, _, darken, sun], {d, s}} -> darken == d and sun == s end)

      unless bad == [] do
        IO.puts("#{length(bad)} day samples differ; first: #{inspect(hd(bad))}")
        System.halt(1)
      end

      "; #{length(samples)} day samples darken the sky and move the sun alike"

    [] ->
      ""
  end

IO.puts(
  "PASS: #{length(results)} vanilla redstone scenes of 200 ticks (#{writes} writes) power, time, compare, " <>
    "light, open, sound and prime as the block-update engine does, across section lines" <> day
)
