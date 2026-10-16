alias Valimc.Physics.RandomMiningLoot
alias Valimc.Protocol.{Data, ItemStack}
[facts_path, cases_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == JSON.decode!(File.read!("priv/physics/random_mining_loot.json")),
  do: raise("Native random mining loot facts differ")

tool = fn variant, level ->
  if variant == 4 do
    nil
  else
    levels = %{"minecraft:fortune" => level}
    levels = if variant in [2, 5, 6], do: Map.put(levels, "minecraft:silk_touch", 1), else: levels

    component =
      if variant in [1, 6], do: "minecraft:stored_enchantments", else: "minecraft:enchantments"

    %{
      ItemStack.new(if(variant in [3, 5], do: "stone", else: "diamond_pickaxe"))
      | components: %{component => levels}
    }
  end
end

cases = cases_path |> File.read!() |> JSON.decode!()

for [state, variant, level, trace, ids] <- cases do
  Process.put(:loot_draws, trace)

  random = fn request ->
    [next | rest] = Process.get(:loot_draws)

    value =
      case {request, next} do
        {:float, ["float", value]} -> value
        {bound, ["int", bound, value]} -> value
        other -> raise("Random decision request differs #{inspect(other)}")
      end

    Process.put(:loot_draws, rest)
    value
  end

  expected = Enum.map(ids, fn [id, count] -> %ItemStack{item_id: id, count: count} end)

  unless RandomMiningLoot.drops(state, tool.(variant, level), true, random) == {:ok, expected},
    do: raise("Native random loot differs #{inspect({state, variant, level, trace, ids})}")

  unless Process.get(:loot_draws) == [], do: raise("Unused native random decisions")
end

for profile <- facts["blocks"] do
  unless RandomMiningLoot.supported?(profile["state"]),
    do: raise("Missing live random-loot admission")

  unless RandomMiningLoot.drops(profile["state"], ItemStack.new("diamond_pickaxe"), false, fn _ ->
           raise("Wrong-harvest RNG")
         end) == {:ok, []},
         do: raise("Wrong-harvest random loot")
end

unless length(cases) == 380_160 and length(facts["blocks"]) == 4,
  do: raise("Incomplete native random-loot contexts")

Process.delete(:loot_draws)

IO.puts(
  "PASS: #{length(cases)} actual native random loot contexts, exact decision domains and wrong-harvest controls (#{Data.block_state_count()}-state catalog)."
)
