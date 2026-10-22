alias Valimc.Protocol.ItemStack
[cases_path] = System.argv()
rows = cases_path |> File.read!() |> JSON.decode!()
placed = Valimc.Blocks.Placement

for row <- rows do
  before = %ItemStack{
    item_id: row["item"],
    count: row["before"],
    components: %{
      "minecraft:max_stack_size" => 99,
      "minecraft:enchantment_glint_override" => true
    }
  }

  # Every case's item places a block.
  unless placed.placeable?(row["item"]), do: raise("Not a placed item: #{row["item"]}")
  expected = if row["empty"], do: nil, else: %{before | count: row["after"]}

  unless Valimc.Player.Placement.used(before, row["infinite"]) == expected,
    do: raise("Native placement consumption differs: #{inspect(row)}")
end

if rows == [], do: raise("Missing native placement consumption cases")

IO.puts("PASS: #{length(rows)} native survival/creative consumption cases.")
