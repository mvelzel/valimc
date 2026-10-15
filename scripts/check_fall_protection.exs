alias Valimc.{Inventory, PlayerFallProtection}
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
  {:ok, damage} = PlayerFallProtection.damage(inventory, c["amount"])

  unless PlayerFallProtection.points(inventory) == c["protection"] and damage == c["damage"],
    do: raise("Native fall protection differs #{inspect({c, damage})}")
end

IO.puts(
  "PASS: #{length(cases)} native worn protection/armor-bypass/magic damage cases for both landing sources."
)
