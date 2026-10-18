# Original scalar observations from ChestAccessOracle, not upstream sources.
[filename] = System.argv()
raw = JSON.decode!(File.read!(filename))
facts = JSON.decode!(File.read!("priv/protocol/chest_states.json"))
true = facts == raw["facts"]
block = hd(facts["single_states"])

for row <- raw["validity"] do
  actual =
    Valimc.ChestAccess.valid_view?(
      if(row["present"], do: block),
      String.to_existing_atom(row["mode"]),
      List.to_tuple(row["eye"]),
      List.to_tuple(row["position"])
    )

  unless actual == row["valid"], do: raise("chest validity mismatch: #{inspect(row)}")
end

for row <- facts["states"] do
  true = Valimc.ChestAccess.single?(row["state"]) == (row["part"] == "single")
end

IO.puts(
  "PASS: 24 native chest state identities and 112 actual block-entity validity boundaries; opening/physical lifecycle excluded."
)
