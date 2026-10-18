[input] = System.argv()
raw = JSON.decode!(File.read!(input))
facts = JSON.decode!(File.read!("priv/protocol/chest_states.json"))
block = hd(facts["single_states"])

for [above, blocked, provider] <- raw["covers"] do
  true = Valimc.ChestOpening.obstructed?(above, false) == blocked
  true = Valimc.ChestOpening.provider?(block, true, above, false) == provider
end

for [block, present, cat, blocked, provider] <- raw["contexts"] do
  true = Valimc.ChestOpening.obstructed?(Valimc.Protocol.Data.block("air"), cat == 2) == blocked

  true =
    Valimc.ChestOpening.provider?(block, present, Valimc.Protocol.Data.block("air"), cat == 2) ==
      provider
end

IO.puts(
  "PASS: #{length(raw["covers"])} native above-block providers and #{length(raw["contexts"])} single-chest entity/cat contexts; live opening/dispatch excluded."
)
