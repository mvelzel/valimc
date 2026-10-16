alias Valimc.{Inventory, PlayerArmor, PlayerDamageProtection}
alias Valimc.Physics.ArmorDamage
alias Valimc.Protocol.{ItemStack, ItemTypes}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  slots =
    Map.new(c["gear"], fn gear ->
      stack = %{
        ItemStack.new(
          if(gear["item_id"], do: ItemTypes.item(gear["item_id"])["name"], else: "stone")
        )
        | components: %{
            "minecraft:enchantments" => gear["direct"],
            "minecraft:stored_enchantments" => gear["stored"]
          },
          removed:
            if(gear["removed"],
              do: MapSet.new(["minecraft:attribute_modifiers"]),
              else: MapSet.new()
            )
      }

      {gear["slot"], stack}
    end)

  inventory = %Inventory{slots: slots}
  source = String.to_existing_atom(c["source"])
  {:ok, damage} = PlayerDamageProtection.damage(inventory, source, c["amount"])

  unless PlayerDamageProtection.points(inventory, source) == c["protection"] and
           damage == c["damage"],
         do: raise("Native environmental protection differs #{inspect({c, damage})}")

  if Map.has_key?(c, "armored") do
    attributes = PlayerArmor.attributes(inventory)

    {:ok, armored} =
      if PlayerDamageProtection.wears_armor?(source),
        do: ArmorDamage.reduce(c["amount"], attributes.armor, attributes.toughness),
        else: {:ok, c["amount"]}

    unless attributes.armor == c["armor"] and attributes.toughness == c["toughness"] and
             armored == c["armored"] and
             c["wear_calls"] == if(PlayerDamageProtection.wears_armor?(source), do: 1, else: 0) and
             (c["wear_calls"] == 0 or c["wear_amount"] == c["amount"]),
           do: raise("Native fire armor/selection order differs #{inspect(c)}")
  end
end

IO.puts(
  "PASS: #{length(cases)} native worn protection/armor/magic damage cases and admitted source-specific armor callbacks."
)
