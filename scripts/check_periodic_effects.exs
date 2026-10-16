alias Valimc.{PeriodicEffect, PlayerHealth, StatusEffect}
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

f32 = fn number ->
  <<value::float-32>> = <<number::float-32>>
  value
end

for row <- rows do
  initial = Enum.map(row["initial"], &List.to_tuple/1)
  health = %PlayerHealth{value: f32.(row["health"]), maximum: f32.(row["maximum"])}
  {:ok, action} = PeriodicEffect.request(row["id"], initial, row["age"], health)

  actions =
    case action do
      :none -> []
      {:heal, amount} -> [["heal", amount]]
      {:hurt, source, amount} -> [["hurt", Atom.to_string(source), amount]]
    end

  {:ok, next, remains, promoted} = StatusEffect.tick(initial)

  unless actions == row["actions"] and Enum.map(next, &Tuple.to_list/1) == row["next"] and
           remains == row["remains"] and if(promoted, do: 1, else: 0) == row["promotions"],
         do: raise("Native periodic effect differs #{inspect(row)}; got #{inspect(actions)}")
end

IO.puts(
  "PASS: #{length(rows)} native periodic action/duration/promotion ticks; owner composition excluded."
)
