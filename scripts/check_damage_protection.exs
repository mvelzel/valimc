alias Valimc.{Inventory, PlayerDamageProtection}
alias Valimc.Protocol.ItemStack
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  slots =
    Map.new(c["gear"], fn gear ->
      stack = %{
        ItemStack.new("stone")
        | components: %{
            "minecraft:enchantments" => gear["direct"],
            "minecraft:stored_enchantments" => gear["stored"]
          }
      }

      {gear["slot"], stack}
    end)

  inventory = %Inventory{slots: slots}
  source = String.to_existing_atom(c["source"])
  {:ok, damage} = PlayerDamageProtection.damage(inventory, source, c["amount"])

  unless PlayerDamageProtection.points(inventory, source) == c["protection"] and
           damage == c["damage"],
         do: raise("Native environmental protection differs #{inspect({c, damage})}")
end

IO.puts(
  "PASS: #{length(cases)} native worn protection/armor-bypass/magic damage cases, including void."
)
