[input] = System.argv()
raw = JSON.decode!(File.read!(input))
facts = JSON.decode!(File.read!("priv/protocol/chest_states.json"))
block = hd(facts["single_states"])

for [above, blocked, provider] <- raw["covers"] do
  true = Valimc.Menus.MenuAccess.obstructed?(above, false) == blocked
  true = Valimc.Menus.MenuAccess.provider?(block, true, above, false) == provider
end

for [block, present, cat, blocked, provider] <- raw["contexts"] do
  true =
    Valimc.Menus.MenuAccess.obstructed?(Valimc.Protocol.Data.block("air"), cat == 2) == blocked

  true =
    Valimc.Menus.MenuAccess.provider?(block, present, Valimc.Protocol.Data.block("air"), cat == 2) ==
      provider
end

# Ender chests (VMC-032c3): the same cover bits, no cat; checked through the
# menu grant an ender chest's owner decides.
ender = Valimc.Data.Blocks.default_state("ender_chest")
true = length(raw["ender_covers"]) == length(raw["covers"])
true = raw["ender_sitting_cat_opens"]

grant = %{
  kind: :open,
  mode: :survival,
  eye: {0.5, 1.62, 2.5},
  hand: :main,
  secondary: false,
  main: false,
  off: false
}

for {[above, _, _], opens} <- Enum.zip(raw["covers"], raw["ender_covers"]) do
  now = System.monotonic_time(:millisecond)

  decision =
    Valimc.Menus.MenuAccess.authorize(
      :ender_chest,
      ender,
      Valimc.Blocks.EnderChest.view(),
      above,
      {0, 0, 0},
      Map.put(grant, :expires, now + 100),
      now
    )

  true = match?({:ender_chest, ^ender, _}, decision) == opens
  true = opens or decision == {:error, :blocked_chest}
end

IO.puts("PASS: #{length(raw["ender_covers"])} native ender chest covers through its menu grant")

IO.puts(
  "PASS: #{length(raw["covers"])} native above-block providers and #{length(raw["contexts"])} single-chest entity/cat contexts; live opening/dispatch excluded."
)
