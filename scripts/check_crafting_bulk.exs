alias Valimc.{Inventory, TableMenu}
alias Valimc.Protocol.ItemStack
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

stack = fn
  nil ->
    nil

  [id, count, glint | rest] ->
    components =
      if glint == nil, do: %{}, else: %{"minecraft:enchantment_glint_override" => glint}

    components =
      case rest do
        [damage] when damage != nil -> Map.put(components, "minecraft:damage", damage)
        _ -> components
      end

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

unless facts["version"] == "26.3" and length(facts["cases"]) == 3_392,
  do: raise("Incomplete bulk observations")

Enum.each(facts["cases"], fn row ->
  size = row["size"]

  {initial, expected, physical, carried, drops} =
    case row["observation"] do
      [creative, before, cursor, _actions, expected, carried, drops] ->
        {%Inventory{slots: slots.(before), carried: stack.(cursor), infinite_materials: creative},
         expected, nil, carried, drops}

      [creative, before, grid, cursor, _actions, expected, physical, carried, drops] ->
        {%Inventory{
           slots: slots.(before),
           table_inputs: grid |> Enum.map(stack) |> List.to_tuple(),
           carried: stack.(cursor),
           infinite_materials: creative
         }, expected, physical, carried, drops}
    end

  original = Inventory.crafting_result(initial)

  {next, actual} =
    Enum.reduce_while(1..20, {initial, []}, fn _, {inv, drops} ->
      current = Inventory.crafting_result(inv)

      if current != nil and ItemStack.same_item?(current, original) do
        {:ok, next, batch} = Inventory.plan_click(inv, :throw, 0, 1)
        unless length(batch) <= 5, do: raise("Unbounded bulk plan")
        if batch == [], do: {:halt, {next, drops}}, else: {:cont, {next, drops ++ batch}}
      else
        {:halt, {inv, drops}}
      end
    end)

  visible = if size == 2, do: Inventory.display_contents(next), else: TableMenu.contents(next)

  unless same_list.(visible, Enum.map(expected, stack)) and same.(next.carried, stack.(carried)) and
           same_list.(actual, Enum.map(drops, stack)) and
           (physical == nil or
              same_list.(Enum.take(Inventory.contents(next), 46), Enum.map(physical, stack))),
         do:
           raise(
             "Native bulk differs #{inspect(%{size: size, initial: initial, visible: visible, expected: Enum.map(expected, stack), physical: physical, drops: actual, expected_drops: Enum.map(drops, stack)}, limit: :infinity)}"
           )
end)

IO.puts(
  "PASS:3392 native bulk traces through bounded plans; exact inputs/result/cursor/physical storage and drop order."
)
