# VMC-025e: ValiMC's structure placement and starts equal vanilla's
# (StructureOracle). Per seed: the structure sets that can occur, every
# concentric ring position, every start in the oracle's chunks (as canonical
# NBT: pieces with type, box, orientation, depth and their own fields), and per
# window every set's placement chunks and every chunk's references. Sets with
# a structure type ValiMC does not generate yet are skipped, and so are their
# starts and references; the summary names them.
[facts_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

{:ok, _} = Application.ensure_all_started(:crypto)
alias Valimc.Native

set_structures =
  Application.app_dir(:valimc, "priv/worldgen/structure_sets.json")
  |> File.read!()
  |> JSON.decode!()
  |> Map.new(fn {id, set} -> {id, Enum.map(set["structures"], & &1["structure"])} end)

pairs = fn flat -> flat |> Enum.chunk_every(2) |> Enum.map(fn [x, z] -> {x, z} end) end

compare = fn label, ours, want ->
  ours = Enum.sort(ours)
  want = Enum.sort(want)

  if ours == want,
    do: [],
    else: [{label, missing: Enum.take(want -- ours, 3), extra: Enum.take(ours -- want, 3)}]
end

{failures, totals} =
  Enum.reduce(facts["cases"], {[], %{starts: 0, rings: 0, placements: 0, references: 0}}, fn c,
                                                                                             {failures,
                                                                                              totals} ->
    seed = String.to_integer(c["seed"])
    source = c["source"]
    {:ok, state} = Valimc.Worldgen.new(seed, c["settings"])
    {:ok, {possible, rings}} = Native.worldgen_structure_state(state, source)

    ring_failures =
      for {set, positions} <- c["rings"],
          ours = Enum.find_value(rings, [], fn {s, p} -> if s == set, do: p end),
          ours != pairs.(positions),
          do:
            {seed, source, :rings, set,
             first_difference:
               Enum.find(Enum.zip(ours, pairs.(positions)), fn {a, b} -> a != b end)}

    {:ok, {starts, skipped}} =
      Native.worldgen_structure_starts(state, source, pairs.(c["chunks"]))

    skipped_structures = MapSet.new(Enum.flat_map(skipped, &set_structures[&1]))
    included = fn structure -> not MapSet.member?(skipped_structures, structure) end

    want_starts =
      for s <- c["starts"], included.(s["structure"]) do
        [x, z] = s["chunk"]
        {x, z, s["structure"], s["nbt"]}
      end

    start_failures =
      compare.({seed, source, :starts}, starts, want_starts)
      |> Enum.map(fn {label, diff} -> {label, diff} end)

    windows = c["placements"] |> Enum.group_by(& &1["window"])

    {window_failures, placement_count, reference_count} =
      Enum.reduce(windows, {[], 0, 0}, fn {[x0, z0, size] = window, entries}, {acc, pc, rc} ->
        {:ok, {placements, references}} =
          Native.worldgen_structure_window(state, source, {x0, z0}, size)

        placement_failures =
          for %{"set" => set, "chunks" => chunks} <- entries,
              ours = Enum.find_value(placements, [], fn {s, p} -> if s == set, do: p end),
              Enum.sort(ours) != Enum.sort(pairs.(chunks)),
              do: {seed, source, :placements, window, set}

        want_refs =
          for r <- c["references"],
              [x, z] = r["chunk"],
              x >= x0 + 8 and x < x0 + size - 8 and z >= z0 + 8 and z < z0 + size - 8,
              included.(r["structure"]),
              do: {x, z, r["structure"], Enum.sort(pairs.(r["sources"]))}

        ours_refs = for {x, z, s, sources} <- references, do: {x, z, s, Enum.sort(sources)}

        {acc ++
           placement_failures ++
           compare.({seed, source, :references, window}, ours_refs, want_refs),
         pc + Enum.sum_by(entries, &div(length(&1["chunks"]), 2)),
         rc + Enum.sum_by(want_refs, fn {_, _, _, sources} -> length(sources) end)}
      end)

    possible_failures =
      if possible == c["possible_sets"],
        do: [],
        else: [{seed, source, :possible_sets, possible, c["possible_sets"]}]

    {failures ++ possible_failures ++ ring_failures ++ start_failures ++ window_failures,
     %{
       totals
       | starts: totals.starts + length(want_starts),
         rings: totals.rings + Enum.sum_by(c["rings"], fn {_, p} -> div(length(p), 2) end),
         placements: totals.placements + placement_count,
         references: totals.references + reference_count
     }
     |> Map.update(:skipped, MapSet.new(skipped), &MapSet.union(&1, MapSet.new(skipped)))}
  end)

if failures != [] do
  for failure <- Enum.take(failures, 8), do: IO.inspect(failure, limit: 50, printable_limit: 2000)
  IO.puts("FAIL: #{length(failures)} structure comparisons differ from vanilla's")
  System.halt(1)
end

skipped = totals |> Map.get(:skipped, MapSet.new()) |> Enum.sort()

IO.puts(
  "PASS: #{length(facts["cases"])} seeds and dimensions: #{totals.rings} ring positions, #{totals.placements} placement chunks, " <>
    "#{totals.starts} structure starts and #{totals.references} references equal vanilla's" <>
    if(skipped == [], do: "", else: " (sets not generated yet: #{Enum.join(skipped, ", ")})")
)
