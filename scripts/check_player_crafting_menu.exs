alias Valimc.Menus.{Inventory, Menu, Click}
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

Enum.each(cases, fn [creative, before, cursor, clicks, expected, carried, []] ->
  slots =
    before
    |> Enum.with_index()
    |> Enum.reject(fn {s, _} -> s == nil end)
    |> Map.new(fn {s, slot} -> {slot, stack.(s)} end)

  initial = %Inventory{infinite_materials: creative, slots: slots, carried: stack.(cursor)}

  result =
    Enum.reduce(clicks, initial, fn [action, slot, button], inv ->
      case Click.plan(Menu.inventory(), nil, inv, Enum.at(actions, action), slot, button) do
        {:ok, nil, next, []} ->
          next

        other ->
          raise "Crafting menu refused #{inspect({creative, before, cursor, clicks, other})}"
      end
    end)

  unless Inventory.display_contents(result) == Enum.map(expected, stack) and
           result.carried == stack.(carried) and Inventory.get(result, 0) == nil,
         do:
           raise(
             "Native crafting menu differs #{inspect({creative, before, cursor, clicks, expected, carried, result})}"
           )
end)

unless length(cases) == 3_536, do: raise("Incomplete actual crafting-menu contexts")
IO.puts("PASS:#{length(cases)} actual native player-menu contexts.")
