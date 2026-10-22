alias Valimc.Protocol.ItemStack
[cases_path] = System.argv()
rows = cases_path |> File.read!() |> JSON.decode!()
facts = "priv/physics/placement.json" |> File.read!() |> JSON.decode!()
states = Map.new(facts["plain"], fn {item, state} -> {String.to_integer(item), state} end)

states =
  Enum.reduce(facts["pillars"], states, fn pillar, states ->
    Map.put(states, pillar["item"], Enum.at(pillar["states"], 1))
  end)

states =
  Enum.reduce(facts["slabs"], states, fn slab, states ->
    Map.put(states, slab["item"], Enum.at(slab["states"], 3))
  end)

for row <- rows do
  before = %ItemStack{
    item_id: row["item"],
    count: row["before"],
    components: %{
      "minecraft:max_stack_size" => 99,
      "minecraft:enchantment_glint_override" => true
    }
  }

  # Every case's item places a block the facts know.
  Map.fetch!(states, row["item"])
  expected = if row["empty"], do: nil, else: %{before | count: row["after"]}

  unless Valimc.Player.Placement.used(before, row["infinite"]) == expected,
    do: raise("Native placement consumption differs: #{inspect(row)}")
end

unless length(rows) == 3510, do: raise("Missing native placement consumption cases")

IO.puts("PASS: 3,510 native survival/creative consumption cases.")
