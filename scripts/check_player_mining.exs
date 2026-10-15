alias Valimc.{Inventory, PlayerMining}
alias Valimc.Protocol.{Data, ItemStack}
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

bits = fn
  :infinity -> "7f800000"
  value -> Base.encode16(<<value::float-32>>, case: :lower)
end

unless Map.new(PlayerMining.attributes(%Inventory{}), fn {k, v} -> {Atom.to_string(k), v} end) ==
         facts["baseline"],
       do: raise("Native player mining defaults differ")

for row <- facts["equipment"] do
  component =
    if row["stored"], do: "minecraft:stored_enchantments", else: "minecraft:enchantments"

  stack = %{
    ItemStack.new("iron_pickaxe")
    | components: %{component => %{row["enchantment"] => row["level"]}}
  }

  inventory = %Inventory{selected: 7, slots: %{43 => ItemStack.new("iron_pickaxe")}}
  inventory = %{inventory | slots: Map.put(inventory.slots, row["slot"], stack)}

  attributes =
    Map.new(PlayerMining.attributes(inventory), fn {k, v} -> {Atom.to_string(k), v} end)

  unless attributes == row["attributes"],
    do: raise("Native mining equipment differs #{inspect(row)}")

  actual =
    for name <- ["stone", "dirt"],
        water <- [false, true],
        ground <- [false, true],
        do: bits.(PlayerMining.speed(inventory, Data.block(name), water, ground))

  unless actual == row["speed_bits"],
    do: raise("Native geared mining speed differs #{inspect(row)}")
end

for row <- facts["speeds"] do
  stack = %ItemStack{
    item_id: row["item"],
    removed: if(row["removed"], do: MapSet.new(["minecraft:tool"]), else: MapSet.new())
  }

  inventory = %Inventory{
    selected: 7,
    slots: %{43 => stack, 36 => ItemStack.new("diamond_pickaxe")}
  }

  inventory =
    if level = row["head_aqua"] do
      helmet = %{
        ItemStack.new("iron_helmet")
        | components: %{"minecraft:enchantments" => %{"minecraft:aqua_affinity" => level}}
      }

      %{inventory | slots: Map.put(inventory.slots, 5, helmet)}
    else
      inventory
    end

  actual = PlayerMining.speed(inventory, row["state"], row["water"], row["ground"])

  unless bits.(actual) == row["speed_bits"] and
           PlayerMining.harvest?(inventory, row["state"]) == row["correct"],
         do: raise("Native stock player mining differs #{inspect({row, actual})}")

  {:ok, rate} = PlayerMining.rate(inventory, row["state"], row["water"], row["ground"])

  unless bits.(rate) == row["rate_bits"],
    do: raise("Native composed mining rate differs #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(facts["equipment"])} native mining equipment attributes, #{length(facts["equipment"]) * 8} geared speed contexts and #{length(facts["speeds"])} stock Player speed/harvest contexts; all Efficiency/Aqua Affinity levels0..255."
)
