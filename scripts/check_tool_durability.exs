alias Valimc.Durability
alias Valimc.Protocol.{ItemStack, ItemTypes}
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

for row <- facts["cases"] do
  components = %{}

  components =
    if Map.has_key?(row, "level") do
      name = if row["stored"], do: "minecraft:stored_enchantments", else: "minecraft:enchantments"
      Map.put(components, name, %{"minecraft:unbreaking" => row["level"]})
    else
      components
    end

  components =
    if Map.has_key?(row, "maximum"),
      do:
        Map.merge(components, %{
          "minecraft:max_damage" => row["maximum"],
          "minecraft:max_stack_size" => 1
        }),
      else: components

  components =
    if Map.has_key?(row, "initial_damage"),
      do: Map.put(components, "minecraft:damage", row["initial_damage"]),
      else: components

  components =
    if row["unbreakable"],
      do: Map.put(components, "minecraft:unbreakable", :unit),
      else: components

  removed = if row["removed"], do: MapSet.new([row["removed"]]), else: MapSet.new()

  stack =
    if row["item"] == ItemTypes.id("air"),
      do: nil,
      else: %ItemStack{item_id: row["item"], components: components, removed: removed}

  Process.put(:durability_draws, row["random"])

  random = fn ->
    [value | rest] = Process.get(:durability_draws)
    Process.put(:durability_draws, rest)
    value * 1.0
  end

  {next, broken} = Durability.mine(stack, row["state"], false, random)

  unless Durability.valid_mine?(stack, row["state"], false, next),
    do: raise("Native mining outcome rejected by source validation #{inspect(row)}")

  count = if next, do: next.count, else: 0
  breaks = if broken, do: 1, else: 0

  damage = fn
    nil ->
      nil

    s ->
      if MapSet.member?(s.removed, "minecraft:damage"),
        do: nil,
        else:
          Map.get(
            s.components,
            "minecraft:damage",
            if(MapSet.member?(ItemTypes.defaults(s.item_id).present, "minecraft:damage"), do: 0)
          )
  end

  unless count == row["count"] and breaks == row["breaks"] and
           (count == 0 or damage.(next) == row["damage"]) and
           damage.(broken) == row["broken_damage"] and
           length(row["random"]) - length(Process.get(:durability_draws)) == row["draws"],
         do:
           raise(
             "Native mining durability differs #{inspect(row)} actual=#{inspect({next, broken, Process.get(:durability_draws)})}"
           )

  # Immunity must not sample randomness, including an already damaged/final-use tool.
  unless Durability.mine(stack, row["state"], true, fn -> raise "Immune RNG" end) ==
           {stack, nil},
         do: raise("Infinite-material mining changed the stack")
end

unless facts["item_declarations"] == 1658 and facts["infinite_gates"] == 18,
  do: raise("Incomplete native durability controls")

IO.puts(
  "PASS: #{length(facts["cases"])} native stock mining durability callbacks and infinite-material controls."
)
