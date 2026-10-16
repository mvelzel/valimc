alias Valimc.Physics.ArmorDamage
[path] = System.argv()
rows = :json.decode(File.read!(path))

for row <- rows do
  {:ok, damage} = ArmorDamage.reduce(row["amount"], row["armor"], row["toughness"])

  unless damage == row["damage"],
    do: raise("Native armor reduction differs: #{inspect({row, damage})}")
end

IO.puts("PASS: #{length(rows)} exact native armor/toughness reductions and clamp boundaries.")
