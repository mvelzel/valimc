alias Valimc.{PlayerAirEffects, PlayerEffects}
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  effects = Map.new(row["effects"], &{&1, [{row["ticks"], row["amplifier"], false, true, true}]})
  unless PlayerEffects.valid?(effects), do: raise("Invalid native air effect map")

  unless PlayerAirEffects.breathes?(effects) == row["breathes"] and
           PlayerAirEffects.refills?(effects) == row["refills"],
         do: raise("Native air effect predicates differ #{inspect(row)}")

  expected = if row["breathes"], do: if(row["refills"], do: :refill, else: :hold), else: :none

  unless PlayerAirEffects.policy(effects) == expected,
    do: raise("Native air policy differs #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(rows)} native breathing/refill predicate contexts; no live air composition claim."
)
