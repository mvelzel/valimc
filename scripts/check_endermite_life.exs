alias Valimc.AI.World
alias Valimc.Entity.{Body, MobTicks, Store}
[path] = System.argv()
rows = JSON.decode!(File.read!(path))
unless length(rows) == 10, do: raise("Incomplete endermite lifetime fixtures")
states = for x <- -5..5, y <- 59..70, z <- -5..5, into: %{}, do: {{x, y, z}, 0}
view = Valimc.World.View.of(states)

for row <- rows do
  {:ok, body} = Body.new("minecraft:endermite")

  body = %{
    body
    | no_gravity: true,
      data: %{life: row["initial"]},
      mob: %{body.mob | no_ai: true, persistent: row["persistent"]}
  }

  record = Store.body_record(body, <<30::128>>, {0.5, 64.0, 0.5})
  {:ok, store, {_, id, _}} = Store.create_record(Store.new(), {0, 0}, record)
  entry = store.entries[id]
  world = %World{read: fn p -> states[p] end, goals: false}

  Enum.reduce(row["trace"], entry, fn expected, entry ->
    {[step], _} = MobTicks.steps(view, [{id, entry}], world, nil)
    actual = %{life: step.body.data.life, removed: :discard in step.effects}

    unless actual == %{life: expected["life"], removed: expected["removed"]},
      do: raise("NoAI endermite #{inspect(row)}: #{inspect(actual)} != #{inspect(expected)}")

    %{entry | body: step.body}
  end)
end

IO.puts(
  "PASS: ten native NoAI endermite lifecycle traces through the live mob ticker, persistence and the 2400-tick boundary"
)
