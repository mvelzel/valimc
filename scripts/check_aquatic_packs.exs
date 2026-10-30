# Vanilla's aquatic packs finishing their spawn as one group (AquaticPackOracle)
# against `Native.mob_finalize/2`'s packs (`valimc_core::mobs::ai::spawn_group`):
# each pack's members in spawn order with their own randoms and the section's
# level random, a tropical fish school's decision as the kernel made it. Each
# member's mind is made first and keeps the random the oracle recorded after
# its constructor (`mob_oracle_ai_finalize`: an axolotl's brain drew its
# sensors' countdowns before). Every member's age, variant, size, own random
# after, school and leader, the level random after, and the random boundaries
# of each prefix of the pack must equal vanilla's.
alias Valimc.Entity.{Body, Store}
alias Valimc.Native

[path] = System.argv()
Valimc.Entity.MobFacts.install!()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 1280, do: raise("Incomplete aquatic pack fixtures")

finalize = fn scene, entries ->
  {:ok, {out, [level]}} = Native.mob_oracle_ai_finalize(entries, [scene["random_before"]])
  {Map.new(out, fn {record, school} -> {record.uuid, {record, school}} end), level}
end

for scene <- cases do
  reason =
    Map.fetch!(%{"natural" => :natural, "chunk_generation" => :chunk_generation}, scene["reason"])

  entries =
    for row <- scene["members"] do
      {:ok, body} = Body.spawned(scene["type"], reason)
      body = %{body | mob: %{body.mob | ai: %{random: row["random_before"]}}}
      uuid = Base.decode16!(row["uuid"], case: :lower)
      record = Store.body_record(body, uuid, {20.5 + row["index"] * 0.25, 64.0, 8.5})
      {0, row["pack"], scene["school_decision"], record}
    end

  # Compare every transition, then the retained leaders after all their followers.
  {finished, level} = finalize.(scene, entries)

  for row <- scene["final"] do
    {record, school} = finished[Base.decode16!(row["uuid"], case: :lower)]
    {leader, size} = school || {nil, 0}

    actual = %{
      age: record.data[:age],
      variant: record.data[:variant],
      size: record.data[:size],
      random_after: record.mob.ai.random,
      school: size,
      leader: leader && Base.encode16(leader, case: :lower)
    }

    for name <- ~w(age variant size random_after school leader), Map.has_key?(row, name) do
      if actual[String.to_existing_atom(name)] != row[name],
        do:
          raise(
            "#{scene["type"]} seed #{scene["seed"]} #{name}: #{inspect(actual)} != #{inspect(row)}"
          )
    end
  end

  true = level == List.last(scene["members"])["level_after"]

  # Prefix admission also checks each member's level/mob random draw boundary.
  for n <- 1..length(entries) do
    {finished, level} = finalize.(scene, Enum.take(entries, n))
    row = Enum.at(scene["members"], n - 1)
    {record, _} = finished[Base.decode16!(row["uuid"], case: :lower)]
    true = record.mob.ai.random == row["random_after"]
    true = level == row["level_after"]
  end
end

IO.puts(
  "PASS: #{length(cases)} native ordered aquatic packs, resets, variants, ages, schools and random transitions"
)
