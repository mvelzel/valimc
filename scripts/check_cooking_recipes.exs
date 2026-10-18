[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.CookingRecipes
alias Valimc.Protocol.{Data, ItemStack}

true =
  raw["version"] == "26.3" and raw["data_version"] == 5023 and
    raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["cases"]) == 14_922
states = Enum.map(~w(furnace smoker blast_furnace), &Data.item_block(Data.item(&1)))

for row <- raw["cases"], speed <- [0.0, 1.0, 2.0] do
  stack =
    if row["item"] == 0 do
      nil
    else
      input = %ItemStack{item_id: row["item"]}

      case row["profile"] do
        0 -> input
        1 -> %{input | components: %{"minecraft:custom_name" => {:string, "Raw"}}}
        2 -> %{input | count: ItemStack.max_stack_size(input)}
      end
    end

  case row["selected"] do
    nil ->
      :none = CookingRecipes.find(stack, Enum.at(states, row["kind"]), speed)

    selected ->
      {:ok, actual} = CookingRecipes.find(stack, Enum.at(states, row["kind"]), speed)

      true =
        actual.key == selected["recipe"] and actual.base_ticks == selected["ticks"] and
          actual.result == %ItemStack{item_id: selected["result"], count: selected["count"]} and
          actual.cook_ticks == Enum.at(selected["times"], trunc(speed))

      true = <<actual.experience::float-32>> == <<selected["xp_bits"]::unsigned-32>>
  end
end

IO.puts(
  "PASS: 14,922 native stock/named/full cooking selections/results/XP bits and44,766 speed-context comparisons; no live processing/XP award claim."
)
