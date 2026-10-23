# Differential check of what the generator grows (`worldgen::compiler::place`) against
# GrowthOracle's trees (VMC-039a, `TreeGrower.growTree`) and bone meal's features (VMC-039b: a
# grass block's grass and flowers, nylium's and moss's features, huge mushrooms): per case its
# plot on an empty flat world of its biome, the growing block's cell and the random's seed;
# whether a tree grew and every block it changed (a feature: the blocks it changed).
[filename] = System.argv()
cases = JSON.decode!(File.read!(filename))["cases"]
rules = Valimc.World.BlockRules.native()
{:ok, worldgen} = Valimc.Worldgen.new(0)

input =
  for c <- cases do
    [x, y, z] = c["pos"]
    {for([cx, cy, cz, s] <- c["cells"], do: {cx, cy, cz, s}), {x, y, z}, c["seed"], c["biome"]}
  end

{:ok, ours} = Valimc.Native.growth_trees(rules, worldgen, input)

failures =
  for {{c, grown}, i} <- Enum.with_index(Enum.zip(cases, ours)),
      cells = Map.new(c["cells"], fn [x, y, z, s] -> {{x, y, z}, s} end),
      after_writes =
        Enum.reduce(c["writes"], cells, fn [x, y, z, s], acc -> Map.put(acc, {x, y, z}, s) end),
      vanilla =
        if(c["grown"],
          do:
            for(
              {{x, y, z}, s} <- after_writes,
              Map.get(cells, {x, y, z}, 0) != s,
              do: {x, y, z, s}
            )
            |> Enum.sort()
        ),
      if(c["kind"] == "tree", do: vanilla != grown, else: (vanilla || []) != (grown || [])),
      do: {i, vanilla, grown}

case failures do
  [] ->
    IO.puts("PASS: #{length(cases)} cases, #{Enum.count(cases, & &1["grown"])} grown")

  [{i, vanilla, ours} | _] ->
    IO.puts("FAIL: #{length(failures)} of #{length(cases)} cases; case #{i}")
    IO.inspect(vanilla && vanilla -- (ours || []), label: "vanilla only", limit: :infinity)
    IO.inspect(ours && ours -- (vanilla || []), label: "ours only", limit: :infinity)
    System.halt(1)
end
