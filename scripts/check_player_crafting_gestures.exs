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

Enum.each(cases, fn [creative, before, cursor, [[action, slot, button]], expected, carried, drops] ->
  slots =
    before
    |> Enum.with_index()
    |> Enum.reject(fn {s, _} -> s == nil end)
    |> Map.new(fn {s, slot} -> {slot, stack.(s)} end)

  initial = %Inventory{infinite_materials: creative, slots: slots, carried: stack.(cursor)}

  observed =
    case Click.plan(Menu.inventory(), nil, initial, Enum.at(actions, action), slot, button) do
      {:ok, nil, result, stacks} -> {:ok, result, stacks}
      other -> other
    end

  case observed do
    {:ok, result, stacks} ->
      unless Inventory.display_contents(result) == Enum.map(expected, stack) and
               result.carried == stack.(carried) and Inventory.get(result, 0) == nil and
               stacks == Enum.map(drops, stack),
             do:
               raise(
                 "Native result gesture differs #{inspect({creative, before, cursor, action, button, expected, carried, result})}"
               )

    other ->
      raise(
        "Native result gesture refused #{inspect({creative, before, cursor, action, button, other})}"
      )
  end
end)

unless length(cases) == 9_466 and Enum.count(cases, &(List.last(&1) != [])) == 2_968,
  do: raise("Incomplete native result gesture coverage")

IO.puts("PASS:9466 native result gestures, including2968 exact single-output drop plans.")
