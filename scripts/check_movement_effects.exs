alias Valimc.Living.Attributes
alias Valimc.Protocol.EffectTypes
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  effects =
    for name <- ["speed", "slowness"], row[name] >= 0, into: %{} do
      {EffectTypes.id(name), [{-1, row[name], false, true, true}]}
    end

  {:ok, result} = Attributes.movement_speed(effects, row["sprint"])
  {26, base, modifiers} = result.attribute
  expected = row["modifiers"] |> Enum.map(&List.to_tuple/1) |> Enum.sort()

  unless base == row["base"] and Enum.sort(modifiers) == expected and
           Enum.map(modifiers, &elem(&1, 0)) == row["evaluation_order"] and
           result.value == row["value"] and result.travel_speed == row["travel_speed"],
         do: raise("Native movement attribute differs #{inspect(row)}: #{inspect(result)}")

  {:ok, removed} = Attributes.movement_speed(%{}, row["sprint"])
  unless removed.value == row["removed"], do: raise("Native effect removal differs")
end

IO.puts(
  "PASS: #{length(rows)} native movement attributes/modifiers/removal; live movement excluded."
)
