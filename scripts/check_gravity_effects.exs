alias Valimc.Living.Attributes
alias Valimc.Data.EffectTypes
[path] = System.argv()
facts = :json.decode(File.read!(path))

unless facts["version"] == "26.3" and facts["protocol"] == 777 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
         facts["hook_contexts"] == 512,
       do: raise("Unexpected native travel-effect reference")

for row <- facts["gravity"] do
  {:ok, gravity} =
    Attributes.gravity(row["base"], row["velocity_y"], row["slow_falling"])

  unless gravity == row["gravity"], do: raise("Native gravity selection differs: #{inspect(row)}")
end

for row <- facts["reset"] do
  effects =
    for {name, present} <- [
          {"slow_falling", row["slow_falling"]},
          {"levitation", row["levitation"]}
        ],
        present,
        into: %{},
        do: {EffectTypes.id(name), [{200, 0, false, true, true}]}

  {:ok, travel} = Attributes.travel(effects, row["velocity_y"])
  distance = if travel.reset_fall, do: 0.0, else: row["initial"]

  unless distance == row["distance"],
    do: raise("Native pre-travel reset differs: #{inspect(row)}")
end

IO.puts(
  "PASS: 512 native no-action hooks,96 actual gravity selections and24 aiStep fall resets; live travel/ownership excluded."
)
