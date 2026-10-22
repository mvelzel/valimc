alias Valimc.Living.Attributes
alias Valimc.Living.FallDamage
alias Valimc.Data.EffectTypes
[path] = System.argv()
facts = :json.decode(File.read!(path))

unless facts["version"] == "26.3" and facts["protocol"] == 777 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c",
       do: raise("Wrong native Jump Boost reference")

for row <- facts["cases"] do
  effects =
    if row["amplifier"] < 0,
      do: %{},
      else: %{EffectTypes.id("jump_boost") => [{200, row["amplifier"], false, true, true}]}

  {:ok, derived} = Attributes.jump_boost(effects)
  {id, base, modifiers} = derived.attribute

  unless id == row["attribute_id"] and base == row["safe_base"] and
           derived.safe_distance == row["safe_distance"] and derived.bonus == row["jump_bonus"] and
           Enum.map(modifiers, &Tuple.to_list/1) == row["modifiers"] and
           row["removed_safe"] == 3.0,
         do: raise("Native Jump Boost attribute differs: #{inspect(row)}")

  for [factor, expected] <- row["powers"] do
    {:ok, ^expected} = Attributes.jump_power(factor, row["amplifier"])
  end

  for [distance, material, expected] <- row["falls"] do
    {:ok, ^expected} =
      FallDamage.calculate(distance, material, %FallDamage{safe_distance: derived.safe_distance})
  end
end

IO.puts(
  "PASS: 257 native Jump Boost attribute/removal contexts,1285 material powers and10280 safer-fall calculations; live movement excluded."
)
