# Differential check of the block-update engine (VMC-077m, `valimc_core::rules::updater` and
# `wire`) against RedstoneWireOracle's scenes: per `Level.setBlock` call the cell writes in
# order, the blocks broken with particles and the ticks scheduled. Redstone torches schedule
# their own ticks when their power changes; those are M3 and left out.
[filename] = System.argv()
facts = JSON.decode!(File.read!(filename))
rules = Valimc.World.BlockRules.native()
%{"state" => stone, "y" => y, "min" => min, "max" => max} = facts["floor"]
floor = for x <- min..max, z <- min..max, do: {x, y, z, stone}

torches = MapSet.new(~w(redstone_torch redstone_wall_torch), &Valimc.Data.Blocks.id/1)

vanilla_step = fn action ->
  {for([x, y, z, s] <- action["writes"], do: {x, y, z, s}),
   for([x, y, z, s] <- action["breaks"], do: {x, y, z, s}),
   for([x, y, z, b, d] <- action["ticks"], not MapSet.member?(torches, b), do: {x, y, z, b, d})}
end

ours_step = fn {writes, destroyed, ticks} ->
  {writes, for({x, y, z, s, true} <- destroyed, do: {x, y, z, s}), ticks}
end

{steps, mismatches} =
  facts["scenes"]
  |> Enum.with_index()
  |> Enum.reduce({0, []}, fn {actions, scene}, {steps, mismatches} ->
    sets = for %{"set" => [x, y, z, s]} <- actions, do: {x, y, z, s}
    {:ok, ours} = Valimc.Native.rules_scene(rules, floor, sets)

    first =
      Enum.zip(actions, ours)
      |> Enum.with_index()
      |> Enum.find(fn {{action, step}, _} -> vanilla_step.(action) != ours_step.(step) end)

    case first do
      nil ->
        {steps + length(actions), mismatches}

      {{action, step}, index} ->
        {steps + index,
         [{scene, index, action["set"], vanilla_step.(action), ours_step.(step)} | mismatches]}
    end
  end)

unless mismatches == [] do
  [{scene, index, set, vanilla, ours} | _] = Enum.reverse(mismatches)

  IO.puts("""
  #{length(mismatches)} of #{length(facts["scenes"])} scenes differ; first: scene #{scene}, step #{index}, set #{inspect(set)}
    vanilla (writes, breaks, ticks): #{inspect(vanilla, limit: :infinity)}
    ours:                            #{inspect(ours, limit: :infinity)}\
  """)

  System.halt(1)
end

IO.puts(
  "PASS: #{steps} block changes in #{length(facts["scenes"])} vanilla redstone scenes write, break " <>
    "and schedule as the block-update engine does."
)
