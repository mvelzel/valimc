# What effects do as an entity goes and as it is hurt (VMC-037p), against
# vanilla's draws from an entity random seeded alike: Weaving's count and
# the 15 cells it tries, Wind Charged's burst strength and Infested's
# silverfish motion.
Valimc.Entity.MobFacts.install!()
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()
[x, y, z] = facts["at"]
id = &Valimc.Data.EffectTypes.id/1

for row <- facts["weaving"] do
  [{:cobwebs, count, cells}] =
    Valimc.Native.effect_removal([id.("weaving")], {x, y, z}, row["seed"])

  unless count == row["count"] and Enum.map(cells, &Tuple.to_list/1) == row["cells"],
    do: raise("Weaving differs for seed #{row["seed"]}: #{inspect({count, cells})}")
end

for row <- facts["wind"] do
  [{:wind_burst, strength}] =
    Valimc.Native.effect_removal([id.("wind_charged")], {x, y, z}, row["seed"])

  unless strength == row["strength"],
    do: raise("Wind Charged differs for seed #{row["seed"]}: #{strength}")
end

for row <- facts["infested"] do
  velocities =
    Valimc.Native.effect_infested(row["seed"], row["pitch"] * 1.0, row["yaw"] * 1.0)
    |> Enum.map(&Tuple.to_list/1)

  unless velocities == row["velocities"],
    do: raise("Infested differs for #{inspect(row)}: #{inspect(velocities)}")
end

spawned = Enum.count(facts["infested"], &(&1["velocities"] != []))

IO.puts(
  "PASS: Weaving and Wind Charged over #{length(facts["weaving"])} seeds and Infested over #{length(facts["infested"])} hurts (#{spawned} releasing silverfish) equal vanilla's draws."
)
