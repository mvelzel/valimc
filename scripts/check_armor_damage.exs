alias Valimc.Living.Damage
[path] = System.argv()
rows = :json.decode(File.read!(path))

for row <- rows do
  {:ok, damage} = Damage.armor_absorb(row["amount"], row["armor"], row["toughness"])

  unless damage == row["damage"],
    do: raise("Native armor reduction differs: #{inspect({row, damage})}")
end

IO.puts("PASS: #{length(rows)} exact native armor/toughness reductions and clamp boundaries.")
