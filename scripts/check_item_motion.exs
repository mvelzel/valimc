alias Valimc.Physics.ItemMotion
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
unless length(cases) == 1152, do: raise("Incomplete native item-motion observations")

Enum.each(cases, fn row ->
  facts = %ItemMotion{
    fluid: Enum.at([:air, :water, :lava], row["fluid"]),
    depth: row["depth"],
    on_ground: row["ground"],
    no_gravity: row["no_gravity"],
    refresh: rem(row["tick"] + 1, 4) == 0
  }

  {:ok, prepared} = ItemMotion.prepare(List.to_tuple(row["input"]), facts)
  request = if prepared.request, do: Tuple.to_list(prepared.request)

  velocity =
    if prepared.request do
      {:ok, velocity} = ItemMotion.finish(prepared.velocity, facts.on_ground, row["friction"])
      velocity
    else
      prepared.velocity
    end

  unless request == row["requested"] and Tuple.to_list(velocity) == row["velocity"] and
           row["age"] == 1 and row["pickup_delay"] == 39,
         do:
           raise(
             "Native item motion differs #{inspect({row, prepared, velocity}, limit: :infinity)}"
           )
end)

IO.puts(
  "PASS:1152 actual native item ticks; exact acceleration/request/drag/bounce with supplied contacts/collision and refresh phase. Lifecycle, merging and live ownership excluded."
)
