alias Valimc.{ArmorDurability, Inventory}
alias Valimc.Protocol.{ItemStack, Packets}
[facts_path, cases_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == JSON.decode!(File.read!("priv/protocol/item_armor_wear.json")),
  do: raise("Pinned native armor-wear facts differ")

for {slot, event} <- facts["break_events"] do
  {_, body} = Packets.armor_break(128, String.to_integer(slot))

  unless IO.iodata_to_binary(body) == <<128::signed-32, event>>,
    do: raise("Native armor-break packet differs")
end

for {source, exhaustion} <- facts["exhaustion"] do
  unless Valimc.PlayerDamageProtection.exhaustion(String.to_existing_atom(source)) == exhaustion,
    do: raise("Native environmental damage exhaustion differs")
end

cases = cases_path |> File.read!() |> JSON.decode!()

for c <- cases do
  components = %{}

  components =
    if c["maximum"],
      do:
        Map.merge(components, %{
          "minecraft:max_stack_size" => 1,
          "minecraft:max_damage" => c["maximum"]
        }),
      else: components

  components =
    if Map.has_key?(c, "initial_damage"),
      do: Map.put(components, "minecraft:damage", c["initial_damage"]),
      else: components

  components =
    if c["unbreakable"], do: Map.put(components, "minecraft:unbreakable", :unit), else: components

  components =
    if c["level"],
      do:
        Map.put(
          components,
          if(c["stored"], do: "minecraft:stored_enchantments", else: "minecraft:enchantments"),
          %{"minecraft:unbreaking" => c["level"]}
        ),
      else: components

  removed = if c["removed"], do: MapSet.new([c["removed"]]), else: MapSet.new()
  stack = %ItemStack{item_id: c["item"], components: components, removed: removed}
  Process.put(:wear_draws, 0)

  random = fn ->
    Process.put(:wear_draws, Process.get(:wear_draws) + 1)
    c["random"]
  end

  {:ok, inventory, broken} =
    ArmorDurability.damage(
      %Inventory{slots: %{c["slot"] => stack}},
      String.to_existing_atom(c["source"]),
      c["amount"],
      false,
      random
    )

  actual = Inventory.get(inventory, c["slot"])

  actual_damage =
    if actual,
      do:
        Map.get(
          actual.components,
          "minecraft:damage",
          if(
            MapSet.member?(
              Valimc.Protocol.ItemTypes.defaults(actual.item_id).present,
              "minecraft:damage"
            ) and not MapSet.member?(actual.removed, "minecraft:damage"),
            do: 0
          )
        )

  # Native get(component) returns null on a stack after shrink-to-empty.
  broken_damage =
    case broken do
      [] -> nil
      [{_, stack}] -> stack.components["minecraft:damage"]
    end

  unless if(actual, do: actual.count, else: 0) == c["count"] and actual_damage == c["damage"] and
           length(broken) == c["breaks"] and broken_damage == c["broken_damage"] and
           Process.get(:wear_draws) == c["draws"],
         do:
           raise(
             "Native armor wear differs #{inspect({c, actual, broken, Process.get(:wear_draws)})}"
           )
end

IO.puts(
  "PASS: #{length(cases)} native environmental armor-wear cases, exact draws, break payloads and pinned facts."
)
