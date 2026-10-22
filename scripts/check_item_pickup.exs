alias Valimc.Menus.Inventory
alias Valimc.Protocol.ItemStack
[path] = System.argv()

decode = fn bytes ->
  {:ok, stack} = ItemStack.decode(Base.decode16!(bytes, case: :lower))
  stack
end

slots = fn values ->
  Map.new(values, fn {slot, stack} -> {String.to_integer(slot), decode.(stack)} end)
end

cases = :json.decode(File.read!(path))

for {row, n} <- Enum.with_index(cases) do
  inventory = %Inventory{
    slots: slots.(row["before"]),
    selected: row["selected"],
    infinite_materials: row["infinite"]
  }

  {:ok, next, remainder, callback} = Inventory.pickup_stack(inventory, decode.(row["stack"]))

  unless next.slots == slots.(row["after"]) and remainder == decode.(row["remainder"]) and
           callback == row["callback"],
         do:
           raise("pickup #{n}: #{inspect({next, remainder, callback})}, expected #{inspect(row)}")
end

IO.puts("PASS: #{length(cases)} actual native insertion/remainder/callback observations.")
