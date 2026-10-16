alias Valimc.Inventory
alias Valimc.Protocol.ItemStack
[path] = System.argv()

stack = fn
  nil ->
    nil

  [id, count, nil] ->
    %ItemStack{item_id: id, count: count}

  [id, count, glint] ->
    %ItemStack{
      item_id: id,
      count: count,
      components: %{"minecraft:enchantment_glint_override" => glint}
    }
end

actions = [:pickup, :quick_move, :swap, :clone, :throw, :quick_craft, :pickup_all]
cases = path |> File.read!() |> JSON.decode!()

Enum.each(cases, fn [creative, before, cursor, [[action, slot, button]], expected, carried, drops] ->
  slots =
    before
    |> Enum.with_index()
    |> Enum.reject(fn {s, _} -> s == nil end)
    |> Map.new(fn {s, slot} -> {slot, stack.(s)} end)

  initial = %Inventory{infinite_materials: creative, slots: slots, carried: stack.(cursor)}
  observed = Inventory.plan_click(initial, Enum.at(actions, action), slot, button)

  if drops != [] do
    unless observed == {:error, :unsupported_crafting_overflow},
      do:
        raise(
          "Crafting overflow was not refused #{inspect({creative, before, cursor, action, button, drops, observed})}"
        )
  else
    case observed do
      {:ok, result, []} ->
        unless Inventory.display_contents(result) == Enum.map(expected, stack) and
                 result.carried == stack.(carried) and Inventory.get(result, 0) == nil,
               do:
                 raise(
                   "Native result gesture differs #{inspect({creative, before, cursor, action, button, expected, carried, result})}"
                 )

      other ->
        raise(
          "Native result gesture refused #{inspect({creative, before, cursor, action, button, other})}"
        )
    end
  end
end)

unless length(cases) == 3_754 and Enum.count(cases, &(List.last(&1) != [])) == 112,
  do: raise("Incomplete native result gesture coverage")

IO.puts(
  "PASS:3642 native result gesture contexts and112 native overflow plans explicitly refused."
)
