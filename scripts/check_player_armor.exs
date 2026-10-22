alias Valimc.Living.Armor
alias Valimc.Menus.Inventory
alias Valimc.Protocol.ItemStack
[facts_path, cases_path] = System.argv()

unless :json.decode(File.read!(facts_path)) ==
         :json.decode(File.read!("priv/protocol/item_armor.json")),
       do: raise("Pinned defensive item facts differ")

rows = :json.decode(File.read!(cases_path))

for row <- rows do
  slots =
    Map.new(row["gear"], fn gear ->
      stack = %ItemStack{
        item_id: gear["item_id"],
        removed:
          if(gear["removed"],
            do: MapSet.new(["minecraft:attribute_modifiers"]),
            else: MapSet.new()
          ),
        components: %{
          "minecraft:enchantments" => %{"minecraft:fire_protection" => gear["fire"]},
          "minecraft:stored_enchantments" => %{"minecraft:fire_protection" => gear["stored_fire"]}
        }
      }

      {gear["slot"], stack}
    end)

  actual = Armor.attributes(Armor.equipment(%Inventory{slots: slots}))

  unless actual == %{
           armor: row["armor"],
           toughness: row["toughness"],
           burning_time: row["burning_time"]
         },
         do: raise("Native defensive attributes differ: #{inspect({row, actual})}")
end

IO.puts(
  "PASS: #{length(rows)} native equipped armor/toughness/burning-time attribute cases and pinned facts."
)
