alias Valimc.Living.{Armor, Damage}
alias Valimc.{Inventory}
alias Valimc.Protocol.ItemStack
[path] = System.argv()
facts = :json.decode(File.read!(path))

unless facts["version"] == "26.3" and facts["data_version"] == 5023 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
         facts["enchantment_count"] == 43 and length(facts["sources"]) == 51,
       do: raise("Wrong native immunity reference")

for row <- facts["cases"] do
  stack = %ItemStack{
    item_id: row["item"],
    components: %{
      if(row["stored"], do: "minecraft:stored_enchantments", else: "minecraft:enchantments") => %{
        row["enchantment"] => row["level"]
      }
    }
  }

  inventory = %Inventory{slots: %{row["slot"] => stack}}

  actual =
    Enum.filter(facts["sources"], fn source ->
      Damage.enchantment_immune?(Armor.equipment(inventory), String.to_atom(source))
    end)

  unless actual == row["immune"],
    do: raise("Native enchantment immunity differs: #{inspect(row)}")
end

IO.puts(
  "PASS: #{length(facts["cases"])} native equipment immunity contexts / 51 sources, including explicit level zero and every nonempty stock feet item. Status/mode immunity excluded."
)
