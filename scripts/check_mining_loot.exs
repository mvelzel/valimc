alias Valimc.MiningLoot
alias Valimc.Protocol.{Data, ItemStack}
[facts_path, cases_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == JSON.decode!(File.read!("priv/physics/mining_loot.json")),
  do: raise("Native mining loot facts differ")

enchanted = fn name, component, levels ->
  %{ItemStack.new(name) | components: %{component => levels}}
end

tools = {
  ItemStack.new("diamond_pickaxe"),
  enchanted.("diamond_pickaxe", "minecraft:enchantments", %{"minecraft:silk_touch" => 1}),
  enchanted.("stone", "minecraft:enchantments", %{"minecraft:silk_touch" => 255}),
  enchanted.("diamond_pickaxe", "minecraft:stored_enchantments", %{"minecraft:silk_touch" => 1}),
  enchanted.("diamond_pickaxe", "minecraft:enchantments", %{"minecraft:fortune" => 255}),
  nil,
  enchanted.("diamond_pickaxe", "minecraft:enchantments", %{
    "minecraft:silk_touch" => 1,
    "minecraft:fortune" => 255
  })
}

cases = cases_path |> File.read!() |> JSON.decode!()

for [state, variant, ids] <- cases do
  expected = Enum.map(ids, fn [id, count] -> %ItemStack{item_id: id, count: count} end)

  unless MiningLoot.drops(state, elem(tools, variant), true) == {:ok, expected},
    do: raise("Native deterministic loot differs #{inspect({state, variant, ids})}")
end

for state <- 0..(Data.block_state_count() - 1),
    do:
      if(MiningLoot.drops(state, nil, false) != {:ok, []}, do: raise("Wrong-tool loot #{state}"))

unless facts["supported_blocks"] == 1108 and length(cases) == 231_455,
  do: raise("Incomplete native deterministic loot contexts")

IO.puts(
  "PASS: #{length(cases)} actual native deterministic state/tool loot contexts and all wrong-harvest controls."
)
