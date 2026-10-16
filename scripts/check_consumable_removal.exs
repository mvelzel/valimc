alias Valimc.{ConsumableRemoval, FoodItems}
alias Valimc.Protocol.ItemStack
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()

for fact <- data["facts"] do
  stack = ItemStack.new(fact["item"])
  props = FoodItems.properties(stack)
  {:ok, policy} = ConsumableRemoval.policy(stack, props)

  unless Atom.to_string(policy) == fact["policy"] and props.consumable["ticks"] == fact["ticks"],
    do: raise("Native removal stock facts differ #{inspect(fact)}")
end

for row <- data["cases"] do
  stack = ItemStack.new(row["item"])
  {:ok, policy} = ConsumableRemoval.policy(stack, FoodItems.properties(stack))

  effects =
    Map.new(
      row["initial"],
      &{&1["id"], Enum.map(&1["rungs"], fn rung -> List.to_tuple(rung) end)}
    )

  {:ok, next, removed} = ConsumableRemoval.apply(effects, policy)

  expected =
    Map.new(row["next"], &{&1["id"], Enum.map(&1["rungs"], fn rung -> List.to_tuple(rung) end)})

  unless next == expected and removed == row["removed"] and removed != [] == row["changed"],
    do: raise("Native consumable removal differs #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(data["cases"])} native stock milk/honey removal maps/callbacks; live consumption excluded."
)
