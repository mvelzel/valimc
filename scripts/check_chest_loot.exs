[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.MiningLoot
alias Valimc.Protocol.ItemStack

true =
  raw["version"] == "26.3" and raw["data_version"] == 5023 and
    raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["cases"]) == 672

tools =
  [nil, ItemStack.new("diamond_axe"), ItemStack.new("stone")] ++
    for enchantment <- ["minecraft:silk_touch", "minecraft:fortune"],
        component <- ["minecraft:enchantments", "minecraft:stored_enchantments"],
        do: %{
          ItemStack.new("diamond_pickaxe")
          | components: %{component => %{enchantment => 255}}
        }

compared =
  for row <- raw["cases"], row["metadata"] != 2, Valimc.Block.Chest.single?(row["state"]) do
    false = row["named"]
    {:ok, [stack]} = MiningLoot.drops(row["state"], Enum.at(tools, row["tool"]), true)

    true =
      stack == ItemStack.new("chest") and stack.item_id == row["item"] and
        stack.count == row["count"]

    {:ok, []} = MiningLoot.drops(row["state"], Enum.at(tools, row["tool"]), false)
    row
  end

true = length(compared) == 168

IO.puts(
  "PASS: 168 supported single-chest/tool/metadata self drops and harvest negatives from 672 native contexts; named metadata and double chests remain unadmitted."
)
