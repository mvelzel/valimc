alias Valimc.{ContainerClick, Inventory}
alias Valimc.Protocol.ItemStack
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

unless facts["version"] == "26.3" and facts["protocol"] == 777 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
         length(facts["cases"]) == 23_040,
       do: raise("Incomplete native chest clicks")

stack = fn
  nil ->
    nil

  [id, count, glint, damage, maximum] ->
    components = %{"minecraft:max_stack_size" => maximum}

    components =
      if glint == nil,
        do: components,
        else: Map.put(components, "minecraft:enchantment_glint_override", glint)

    components =
      if damage == nil, do: components, else: Map.put(components, "minecraft:damage", damage)

    %ItemStack{item_id: id, count: count, components: components}
end

for row <- facts["cases"] do
  slots =
    row["player"]
    |> Enum.map(stack)
    |> Enum.with_index()
    |> Enum.reject(fn {value, _} -> value == nil end)
    |> Map.new(fn {value, slot} -> {slot, value} end)

  inventory = %Inventory{
    slots: slots,
    carried: stack.(row["cursor"]),
    infinite_materials: row["creative"]
  }

  storage = row["before"] |> Enum.map(stack) |> List.to_tuple()
  action = Map.fetch!(%{0 => :pickup, 1 => :quick_move, 2 => :swap}, row["action"])

  {:ok, after_storage, after_inventory} =
    ContainerClick.plan(row["rows"], storage, inventory, action, row["slot"], row["button"])

  unless Tuple.to_list(after_storage) == Enum.map(row["after"], stack) and
           Inventory.contents(after_inventory) == Enum.map(row["player_after"], stack) and
           after_inventory.carried == stack.(row["cursor_after"]),
         do:
           raise(
             "Native container click differs: #{inspect(Map.take(row, ~w(rows creative layout slot action button cursor before after player player_after cursor_after)))}: #{inspect({after_storage, after_inventory})}"
           )
end

IO.puts(
  "PASS: #{length(facts["cases"])} actual native chest pickup/shift/number/offhand plans; no shared ownership/durability/world claim."
)
