# VMC-038b: every `AnvilOracle` case through `Valimc.Menus.Anvil`: the
# anvil's result, cost, used repair materials and rename-only flag; the
# grindstone's result and experience base.
alias Valimc.Menus.Anvil
alias Valimc.Protocol.{ItemStack, ItemTypes}

[path] = System.argv()
cases = :json.decode(File.read!(path))

book = ItemTypes.id("minecraft:enchanted_book")

build = fn
  absent when absent in [nil, :null] ->
    nil

  d ->
    stack = %{ItemStack.new(d["item"]) | count: d["count"]}

    component =
      if stack.item_id == book,
        do: "minecraft:stored_enchantments",
        else: "minecraft:enchantments"

    levels = Map.new(d["enchantments"], fn [n, l] -> {n, l} end)

    components =
      stack.components
      |> Map.put(component, levels)
      |> then(&if d["damage"] > 0, do: Map.put(&1, "minecraft:damage", d["damage"]), else: &1)
      |> then(
        &if d["repair_cost"] > 0,
          do: Map.put(&1, "minecraft:repair_cost", d["repair_cost"]),
          else: &1
      )
      |> then(fn c ->
        case d["name"] do
          n when is_binary(n) ->
            Map.put(c, "minecraft:custom_name", {:compound, %{"text" => {:string, n}}})

          _ ->
            c
        end
      end)

    %{stack | components: components}
end

describe = fn
  nil ->
    :null

  s ->
    component =
      if s.item_id == book, do: "minecraft:stored_enchantments", else: "minecraft:enchantments"

    %{
      "item" => ItemTypes.item(s.item_id)["name"],
      "count" => s.count,
      "damage" => ItemStack.component(s, "minecraft:damage") || 0,
      "max_damage" => ItemStack.component(s, "minecraft:max_damage") || 0,
      "repair_cost" => ItemStack.component(s, "minecraft:repair_cost") || 0,
      "name" =>
        case ItemStack.component(s, "minecraft:custom_name") do
          nil -> :null
          name -> Valimc.Text.Render.string(name)
        end,
      "enchantments" =>
        (ItemStack.component(s, component) || %{}) |> Enum.sort() |> Enum.map(&Tuple.to_list/1)
    }
end

normal = fn
  :null -> :null
  %{} = d -> Map.update(d, "name", :null, &(&1 || :null))
end

failures =
  Enum.flat_map(cases, fn c ->
    got =
      case c["kind"] do
        "anvil" ->
          rename = if is_binary(c["rename"]), do: c["rename"]
          r = Anvil.result(build.(c["input"]), build.(c["addition"]), rename, c["creative"])

          %{
            "result" => describe.(r.result),
            "cost" => r.cost,
            "repair_count" => r.repair_count,
            "only_renaming" => r.only_renaming
          }

        "grindstone" ->
          inputs = [build.(c["input"]), build.(c["addition"])]

          %{
            "result" => describe.(Anvil.grind(Enum.at(inputs, 0), Enum.at(inputs, 1))),
            "experience" => Anvil.grind_base(inputs)
          }
      end

    # The oracle's JSON leaves out what is null.
    expected =
      got
      |> Map.keys()
      |> Map.new(&{&1, Map.get(c, &1, :null)})
      |> Map.update!("result", normal)

    if got == expected, do: [], else: [{c, got}]
  end)

case failures do
  [] ->
    IO.puts("PASS: #{length(cases)} anvil and grindstone cases")

  _ ->
    for {c, got} <- Enum.take(failures, 10),
        do: IO.puts("FAIL: #{inspect(c)}\n  got #{inspect(got)}")

    raise "#{length(failures)} of #{length(cases)} anvil and grindstone cases differ"
end
