[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Blocks.MiningLoot
alias Valimc.Protocol.ItemStack

true =
  raw["version"] == "26.3" and raw["data_version"] == 5023 and
    raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["cases"]) == 864
supported = Enum.reject(raw["cases"], &(&1["metadata"] == 2))
true = length(supported) == 648

for row <- supported do
  tool = if row["tool_item"] == 0, do: nil, else: %ItemStack{item_id: row["tool_item"]}

  expected =
    if row["harvest"], do: [%ItemStack{item_id: row["item"], count: row["count"]}], else: []

  {:ok, actual} = MiningLoot.drops(row["state"], tool, row["harvest"])
  true = actual == expected and not row["named"]
end

IO.puts(
  "PASS:648 native unnamed cooking-block self-loot/harvest cases. Named metadata copies names; contents/XP release remains separate and unadmitted."
)
