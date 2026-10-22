alias Valimc.{Inventory, Menu, MenuClick}
alias Valimc.Protocol.ItemStack
[path, catalog_path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

unless JSON.decode!(File.read!(catalog_path)) ==
         JSON.decode!(File.read!("priv/crafting/remainders.json")),
       do: raise("Native remainder catalog differs")

stack = fn
  nil ->
    nil

  [id, count, glint, damage, maximum] ->
    components =
      if glint == nil, do: %{}, else: %{"minecraft:enchantment_glint_override" => glint}

    components =
      if damage == nil, do: components, else: Map.put(components, "minecraft:damage", damage)

    components =
      if maximum == nil,
        do: components,
        else: Map.put(components, "minecraft:max_stack_size", maximum)

    %ItemStack{item_id: id, count: count, components: components}
end

slots = fn values ->
  values
  |> Enum.map(stack)
  |> Enum.with_index()
  |> Enum.reject(fn {v, _} -> v == nil end)
  |> Map.new(fn {v, i} -> {i, v} end)
end

same = fn
  nil, nil ->
    true

  %ItemStack{} = first, %ItemStack{} = second ->
    first.count == second.count and ItemStack.same_item?(first, second)

  _, _ ->
    false
end

same_list = fn first, second ->
  length(first) == length(second) and
    Enum.zip(first, second) |> Enum.all?(fn {a, b} -> same.(a, b) end)
end

unless facts["version"] == "26.3" and length(facts["cases"]) == 2_240,
  do: raise("Incomplete remainder observations")

actions = [:pickup, :quick_move, :swap, :clone, :throw, :quick_craft, :pickup_all]

Enum.each(facts["cases"], fn row ->
  size = row["size"]
  physical = slots.(row["physical_before"])
  inputs = row["before"] |> Enum.slice(1, if(size == 2, do: 4, else: 9)) |> Enum.map(stack)

  initial =
    if size == 2,
      do: %Inventory{
        slots:
          Enum.reduce(Enum.with_index(inputs, 1), physical, fn {value, index}, acc ->
            if value, do: Map.put(acc, index, value), else: acc
          end),
        infinite_materials: row["creative"]
      },
      else: %Inventory{
        slots: physical,
        table_inputs: List.to_tuple(inputs),
        infinite_materials: row["creative"]
      }

  [index, 0, button] = row["action"]
  action = Enum.at(actions, index)
  original = Inventory.crafting_result(initial)
  repeats = action == :quick_move or (action == :throw and button == 1)

  {next, drops} =
    Enum.reduce_while(1..100, {initial, []}, fn count, {inv, drops} ->
      if count == 1 or
           (repeats and Inventory.crafting_result(inv) != nil and
              ItemStack.same_item?(Inventory.crafting_result(inv), original)) do
        {:ok, nil, next, batch} = MenuClick.plan(Menu.crafting(inv), nil, inv, action, 0, button)
        unless length(batch) <= 5, do: raise("Unbounded remainder plan")

        if repeats and batch != [],
          do: {:cont, {next, drops ++ batch}},
          else: {:halt, {next, drops ++ batch}}
      else
        {:halt, {inv, drops}}
      end
    end)

  visible =
    if size == 2,
      do: Inventory.display_contents(next),
      else: elem(Menu.contents(Menu.table(), nil, next), 1)

  unless same_list.(visible, Enum.map(row["after"], stack)) and
           same.(next.carried, stack.(row["cursor"])) and
           same_list.(drops, Enum.map(row["drops"], stack)) and
           same_list.(
             Enum.map(0..45, &if(&1 < 5, do: nil, else: Inventory.get(next, &1))),
             Enum.map(row["physical_after"], stack)
           ),
         do:
           raise(
             "Native remainder differs #{inspect(%{row: row, next: next, drops: drops}, limit: :infinity)}"
           )
end)

IO.puts(
  "PASS:2240 actual remainder menu traces, three recipes, both grids/permissions, selected/offhand/storage, effective max-stack/glint/damage, all result gestures and ordered bounded overflow."
)
