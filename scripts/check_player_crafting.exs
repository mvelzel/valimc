alias Valimc.Crafting2x2
alias Valimc.Protocol.ItemStack
[facts_path, cases_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == JSON.decode!(File.read!("priv/crafting/player_recipes.json")),
  do: raise("Native player recipe facts differ")

cases = cases_path |> File.read!() |> JSON.decode!()

for [ids, patched, name, expected] <- cases do
  grid =
    Enum.map(ids, fn
      0 ->
        nil

      id ->
        stack = %ItemStack{item_id: id}

        if patched,
          do: %{
            stack
            | count: min(17, ItemStack.max_stack_size(stack)),
              components: %{"minecraft:enchantment_glint_override" => true}
          },
          else: stack
    end)

  expected =
    case expected do
      nil -> :none
      [id, count] -> {:ok, %ItemStack{item_id: id, count: count}}
    end

  unless Crafting2x2.result(grid) == expected,
    do: raise("Native player crafting differs #{inspect({ids, patched, name, expected})}")
end

unless length(facts["recipes"]) == 476 and length(cases) == 149_128,
  do: raise("Incomplete native player crafting catalog/contexts")

IO.puts(
  "PASS:476 player recipes and#{length(cases)} native global crafting selections/results, including patched/count controls."
)
