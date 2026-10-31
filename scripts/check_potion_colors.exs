# Potion colours (VMC-034o, `PotionContents.getColor`) against vanilla's: every
# potion's and mixed custom effects' (amplifier-weighted, hidden ones left out).
alias Valimc.Protocol.PotionContents
[path] = System.argv()
rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  effects =
    for [id, amp, visible] <- row["effects"], do: {id, [{200, amp, false, visible, true}]}

  contents = %{PotionContents.empty() | potion: row["potion"], effects: effects}
  actual = Valimc.Protocol.PotionContents.color(contents)

  unless actual == row["color"],
    do: raise("Potion colour differs: #{inspect(row)} gave #{actual}")
end

IO.puts("PASS: #{length(rows)} potion colours equal vanilla's.")
