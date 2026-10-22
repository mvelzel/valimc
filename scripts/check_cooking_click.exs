alias Valimc.{Inventory, Menu, MenuClick}
alias Valimc.CookingBlocks
alias Valimc.Protocol.ItemStack
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

true =
  facts["version"] == "26.3" and facts["protocol"] == 777 and
    facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(facts["cases"]) == 36_036 and length(facts["routes"]) == 4_974

stack = fn
  nil ->
    nil

  [id, count, glint, damage, maximum, removed_fuel] ->
    components = %{"minecraft:max_stack_size" => maximum}

    components =
      if glint == nil,
        do: components,
        else: Map.put(components, "minecraft:enchantment_glint_override", glint)

    components =
      if damage == nil, do: components, else: Map.put(components, "minecraft:damage", damage)

    %ItemStack{
      item_id: id,
      count: count,
      components: components,
      removed: if(removed_fuel, do: MapSet.new(["minecraft:cooking_fuel"]), else: MapSet.new())
    }
end

count = fn
  nil -> 0
  row -> Enum.at(row, 1)
end

kinds = {:furnace, :smoker, :blast_furnace}

{accepted, refused} =
  Enum.reduce(facts["cases"] ++ facts["routes"], {0, 0}, fn row, {accepted, refused} ->
    slots =
      row["player"]
      |> Enum.map(stack)
      |> Enum.with_index()
      |> Enum.reject(fn {item, _} -> item == nil end)
      |> Map.new(fn {item, slot} -> {slot, item} end)

    inventory = %Inventory{
      slots: slots,
      carried: stack.(row["cursor"]),
      infinite_materials: row["creative"]
    }

    storage = row["before"] |> Enum.map(stack) |> List.to_tuple()
    {:ok, block} = CookingBlocks.placement(elem(kinds, row["kind"]), 0.0)
    action = Map.fetch!(%{0 => :pickup, 1 => :quick_move, 2 => :swap}, row["action"])

    result =
      MenuClick.plan(Menu.cooking(block), storage, inventory, action, row["slot"], row["button"])

    if row["overflow"] do
      unless result == {:error, :unsupported_click},
        do: raise("Overflow was not refused: #{inspect(row)} #{inspect(result)}")

      {accepted, refused + 1}
    else
      {:ok, after_storage, after_inventory, []} = result

      held = fn
        nil -> 0
        stack -> stack.count
      end

      taken = max(held.(elem(storage, 2)) - held.(elem(after_storage, 2)), 0)

      unless Tuple.to_list(after_storage) == Enum.map(row["after"], stack) and
               Inventory.contents(after_inventory) == Enum.map(row["player_after"], stack) and
               after_inventory.carried == stack.(row["cursor_after"]) and row["drops"] == [] and
               taken ==
                 max(count.(Enum.at(row["before"], 2)) - count.(Enum.at(row["after"], 2)), 0),
             do: raise("Native cooking click differs: #{inspect(row)} ACTUAL #{inspect(result)}")

      {accepted + 1, refused}
    end
  end)

IO.puts(
  "PASS: #{accepted} native cooking pickup/shift/number/offhand plans; #{refused} explicitly refused overflow proposals; all4974 stock shift routes. Item hooks/XP/journal/live admission remain separate."
)
