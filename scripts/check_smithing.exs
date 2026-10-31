# VMC-038c: every `SmithingOracle` case through `Valimc.Menus.Smithing`.
alias Valimc.Menus.Smithing
alias Valimc.Protocol.{ItemStack, ItemTypes}

[path] = System.argv()
cases = :json.decode(File.read!(path))

build = fn d ->
  stack = %{ItemStack.new(d["item"]) | count: d["count"]}

  components =
    Map.put(
      stack.components,
      "minecraft:enchantments",
      Map.new(d["enchantments"], fn [n, l] -> {n, l} end)
    )

  components =
    if d["damage"] > 0, do: Map.put(components, "minecraft:damage", d["damage"]), else: components

  components =
    if is_binary(d["material"]),
      do:
        Map.put(components, "minecraft:trim", %{
          "material" => d["material"],
          "pattern" => d["pattern"]
        }),
      else: components

  %{stack | components: components}
end

describe = fn
  nil ->
    nil

  s ->
    trim = ItemStack.component(s, "minecraft:trim")

    %{
      "item" => ItemTypes.item(s.item_id)["name"],
      "count" => s.count,
      "damage" => ItemStack.component(s, "minecraft:damage") || 0,
      "material" => trim && trim["material"],
      "pattern" => trim && trim["pattern"],
      "enchantments" =>
        (ItemStack.component(s, "minecraft:enchantments") || %{})
        |> Enum.sort()
        |> Enum.map(&Tuple.to_list/1)
    }
end

expected = fn
  r when r in [nil, :null] -> nil
  r -> Map.merge(%{"material" => nil, "pattern" => nil}, r)
end

failures =
  Enum.flat_map(cases, fn c ->
    got =
      Smithing.result(
        ItemStack.new(c["template"]),
        build.(c["base"]),
        ItemStack.new(c["addition"])
      )
      |> describe.()

    if got == expected.(c["result"]), do: [], else: [{c, got}]
  end)

case failures do
  [] ->
    IO.puts("PASS: #{length(cases)} smithing cases")

  _ ->
    for {c, got} <- Enum.take(failures, 8),
        do: IO.puts("FAIL: #{inspect(c)}\n  got #{inspect(got)}")

    raise "#{length(failures)} of #{length(cases)} smithing cases differ"
end
