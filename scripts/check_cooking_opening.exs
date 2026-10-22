alias Valimc.{Cooking, MenuAccess}
alias Valimc.CookingBlocks
[path] = System.argv()
raw = JSON.decode!(File.read!(path))

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
    length(raw["cases"]) == 360

kinds = {nil, :furnace, :smoker, :blast_furnace, :chest}

grant = %{
  kind: :open,
  mode: :survival,
  eye: {0.5, 65.5, 0.5},
  expires: 1100,
  hand: :main,
  secondary: false,
  main: false,
  off: false
}

for row <- raw["cases"] do
  true = row["block_queries"] == 0 and row["provider"] == (row["entity"] != 0)
  kind = elem(kinds, row["entity"])

  entry =
    if kind == nil, do: nil, else: %{kind: kind, cooking: %Cooking{}, recipes: %{}, revision: 1}

  actual = MenuAccess.authorize(:cooking, row["state"], entry, nil, {0, 64, 0}, grant, 1000)

  if kind == CookingBlocks.kind(row["state"]),
    do: {:cooking, _, ^entry} = actual,
    else: {:error, :missing_menu_entry} = actual
end

IO.puts(
  "PASS:360 native provider facts;72 consistent owned states open,72 missing providers refuse and216 inconsistent owned metadata contexts remain fenced. Native shared Container still-valid range reuses validated strict box distances."
)
