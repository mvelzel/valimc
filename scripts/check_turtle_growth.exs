alias Valimc.AI.World
alias Valimc.Entity.{Body, MobTicks, Store}
[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 32, do: raise("Incomplete turtle growth fixtures")
states = for x <- -5..5, y <- 59..70, z <- -5..5, into: %{}, do: {{x, y, z}, 0}
view = Valimc.World.View.of(states)

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
  world = %World{read: fn p -> states[p] end, goals: false, mob_drops: row["drops"]}

  Enum.reduce(row["trace"], {store.entries[id], world}, fn expected, {entry, world} ->
    {[step], world} = MobTicks.steps(view, [{id, entry}], world, nil)
    gifts = for {:gift, table, _} <- step.effects, do: table
    actual = %{age: step.body.data.age, gifts: gifts}

    unless actual == %{age: expected["age"], gifts: expected["gifts"]},
      do:
        raise(
          "Turtle growth #{inspect(Map.delete(row, "trace"))}: #{inspect(actual)} != native #{inspect(expected)}"
        )

    {%{entry | body: step.body}, world}
  end)
end

IO.puts(
  "PASS: 32 native turtle age-boundary traces through the live ticker, including first-tick adulthood, NoAI, locked age and mob drops"
)
