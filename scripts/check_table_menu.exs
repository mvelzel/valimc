alias Valimc.Inventory
alias Valimc.Protocol.ItemStack
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

stack = fn
  nil ->
    nil

  [id, count, glint, damage] ->
    components = %{}

    components =
      if glint == nil,
        do: components,
        else: Map.put(components, "minecraft:enchantment_glint_override", glint)

    components =
      if damage == nil, do: components, else: Map.put(components, "minecraft:damage", damage)

    %ItemStack{item_id: id, count: count, components: components}
end

unless facts["version"] == "26.3" and facts["menu_type"] == 12 and
         facts["container_id"] == 17 and length(facts["slots"]) == 46 and
         length(facts["cleanup"]) == 24,
       do: raise("Incomplete table menu observations")

{_, open_body} = Valimc.Protocol.Packets.open_table(facts["container_id"])

unless IO.iodata_to_binary(open_body) == Base.decode16!(facts["packet_hex"], case: :lower),
  do: raise("Native crafting table open body differs")

Enum.each(facts["cleanup"], fn [
                                 creative,
                                 disconnected,
                                 layout,
                                 slots,
                                 grid,
                                 cursor,
                                 expected,
                                 carried,
                                 drops
                               ] ->
  unless length(slots) == 46 and length(grid) == 9 and length(expected) == 46,
    do: raise("Incomplete table cleanup cells")

  inventory = %Inventory{
    slots:
      slots
      |> Enum.map(stack)
      |> Enum.with_index()
      |> Enum.reject(fn {value, _} -> value == nil end)
      |> Map.new(fn {value, index} -> {index, value} end),
    selected: 2,
    carried: stack.(cursor),
    infinite_materials: creative,
    table_inputs: grid |> Enum.map(stack) |> List.to_tuple()
  }

  cleanup = if disconnected, do: &Inventory.disconnect/1, else: &Inventory.close/1

  {:ok, next, actual} = cleanup.(inventory)

  unless Inventory.contents(next) == Enum.map(expected, stack) and
           next.carried == stack.(carried) and next.table_inputs == nil and
           actual == Enum.map(drops, stack),
         do:
           raise(
             "Native table cleanup differs #{inspect({creative, disconnected, layout, next, actual})}"
           )
end)

IO.puts(
  "PASS:24 actual table cleanup contexts, both permissions/disconnect states, exact nine inputs/cursor/patch/overflow order."
)
