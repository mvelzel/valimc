# The mob takes its turns in a native section (`MobTicks.native_steps/4`)
# over a scene of air.
alias Valimc.Entity.{Body, MobTicks, Store}
Valimc.Entity.MobFacts.install!()
states = for x <- -5..5, y <- 59..70, z <- -5..5, into: %{}, do: {{x, y, z}, 0}

packed =
  for {{x, y, z}, s} <- states,
      into: <<>>,
      do: <<x::signed-32, y::signed-32, z::signed-32, s::16>>

level = fn drops ->
  %{
    time: 0,
    day: 0,
    difficulty: :normal,
    darken: 0,
    bright: false,
    monsters_burn: false,
    halloween: false,
    mob_griefing: true,
    mob_drops: drops,
    entity_drops: true,
    universal_anger: false,
    goals: false,
    min_y: -64,
    max_y: 319,
    sea_level: 63,
    border: nil,
    knots: [],
    wet: false,
    zoom_seed: 0,
    tops: nil,
    no_chunks: true
  }
end

# A native section holding the mob of `entry`: the section and the entry.
native_entry = fn id, entry, record ->
  section = %Valimc.Entity.NativeMobs{ref: Valimc.Native.mob_section_oracle_new()}
  {:ok, [{^id, _, row}]} = Valimc.Native.mob_section_insert(section.ref, [{id, record}], false)
  :ok = Valimc.Native.mob_section_oracle_prepare(section.ref, id, 0.0, nil)
  {section, %{entry | body: row} |> Map.put(:native, section.ref)}
end

[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 32, do: raise("Incomplete turtle growth fixtures")

for row <- rows do
  {:ok, body} = Body.new("minecraft:turtle")

  body = %{
    body
    | no_gravity: true,
      data: %{body.data | age: row["age"], age_locked: row["locked"]},
      mob: %{body.mob | no_ai: row["no_ai"]}
  }

  record = Store.body_record(body, <<31::128>>, {0.5, 64.0, 0.5})
  {:ok, store, {_, id, _}} = Store.create_record(Store.new(), {0, 0}, record)
  {section, entry} = native_entry.(id, store.entries[id], record)
  env = %{region: nil, level: level.(row["drops"]), players: [], items: [], random: 0}

  Enum.reduce(row["trace"], {entry, env}, fn expected, {entry, env} ->
    {[step], env} = MobTicks.native_steps({:states, packed}, [{id, entry}], section, env)
    gifts = for {:gift, table, _} <- step.effects, do: table
    actual = %{age: step.body.data.age, gifts: gifts}

    unless actual == %{age: expected["age"], gifts: expected["gifts"]},
      do:
        raise(
          "Turtle growth #{inspect(Map.delete(row, "trace"))}: #{inspect(actual)} != vanilla #{inspect(expected)}"
        )

    {%{entry | body: step.body}, env}
  end)
end

IO.puts(
  "PASS: 32 native turtle age-boundary traces through the live ticker, including first-tick adulthood, NoAI, locked age and mob drops, every one a native turtle's"
)
