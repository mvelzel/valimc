alias Valimc.AI.{Mind, World}
alias Valimc.Entity.{Body, Store}

[path] = System.argv()
cases = JSON.decode!(File.read!(path))
unless length(cases) == 1280, do: raise("Incomplete aquatic pack fixtures")

for scene <- cases do
  reason =
    Map.fetch!(%{"natural" => :natural, "chunk_generation" => :chunk_generation}, scene["reason"])

  entries =
    for row <- scene["members"] do
      {:ok, body} = Body.spawned(scene["type"], reason)
      body = %{body | mob: %{body.mob | ai: %Mind{random: row["random_before"]}}}
      uuid = Base.decode16!(row["uuid"], case: :lower)
      record = Store.body_record(body, uuid, {20.5 + row["index"] * 0.25, 64.0, 8.5})
      {:section, row["pack"], scene["school_decision"], Map.put(record, :spawn_body, body)}
    end

  # Compare every transition, then the retained leaders after all their followers.
  {bodies, worlds} =
    Valimc.AI.spawn_groups(entries, %{section: %World{random: scene["random_before"]}})

  for row <- scene["final"] do
    body = bodies[Base.decode16!(row["uuid"], case: :lower)]
    school = Valimc.AI.Mobs.Fish.school(body.mob.ai)

    actual = %{
      age: body.data[:age],
      variant: body.data[:variant],
      size: body.data[:size],
      random_after: body.mob.ai.random,
      school: school.school,
      leader: school.leader && Base.encode16(school.leader, case: :lower)
    }

    for name <- ~w(age variant size random_after school leader), Map.has_key?(row, name) do
      if actual[String.to_existing_atom(name)] != row[name],
        do:
          raise(
            "#{scene["type"]} seed #{scene["seed"]} #{name}: #{inspect(actual)} != #{inspect(row)}"
          )
    end
  end

  true = worlds.section.random == List.last(scene["members"])["level_after"]

  # Prefix admission also checks each member's level/mob random draw boundary.
  for n <- 1..length(entries) do
    {bodies, worlds} =
      Valimc.AI.spawn_groups(Enum.take(entries, n), %{
        section: %World{random: scene["random_before"]}
      })

    row = Enum.at(scene["members"], n - 1)
    body = bodies[Base.decode16!(row["uuid"], case: :lower)]
    true = body.mob.ai.random == row["random_after"]
    true = worlds.section.random == row["level_after"]
  end
end

IO.puts(
  "PASS: #{length(cases)} native ordered aquatic packs, resets, variants, ages, schools and random transitions"
)
