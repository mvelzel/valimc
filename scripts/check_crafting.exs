alias Valimc.Crafting
alias Valimc.Protocol.ItemStack
[scope, facts_path, cases_path] = System.argv()

{source, recipes, count, cells} =
  case scope do
    "player" -> {"player_recipes.json", 476, 149_128, 4}
    "table" -> {"recipes.json", 1_180, 438_672, 9}
  end

facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == JSON.decode!(File.read!(Path.join("priv/crafting", source))),
  do: raise("Native #{scope} recipe facts differ")

cases = cases_path |> File.read!() |> JSON.decode!()

Enum.each(cases, fn [ids, patched, name, expected] ->
  unless length(ids) == cells, do: raise("Wrong crafting grid size")

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
      [id, amount] -> {:ok, %ItemStack{item_id: id, count: amount}}
    end

  unless Crafting.result(grid) == expected,
    do: raise("Native #{scope} crafting differs #{inspect({ids, patched, name, expected})}")
end)

unless length(facts["recipes"]) == recipes and length(cases) == count,
  do: raise("Incomplete native #{scope} crafting coverage")

IO.puts(
  "PASS:#{recipes} #{scope} recipes / #{count} native selections/results, including patched/count controls."
)
