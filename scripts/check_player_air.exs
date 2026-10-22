alias Valimc.Living.{Air, Armor}
alias Valimc.Menus.Inventory
alias Valimc.Protocol.ItemStack
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
unless data["maximum"] == Air.maximum(), do: raise("Native air maximum changed")

unless data["bubble_states"] == Air.bubble_states(),
  do: raise("Native bubble-column states changed")

for c <- data["cases"] do
  unless Air.decrease(c["air"], c["oxygen"], c["draw"]) == c["decrease"] and
           Air.increase(c["air"]) == c["increase"] and
           Air.drowning?(c["air"]) == c["drowning"],
         do: raise("Native air primitive differs #{inspect(c)}")
end

for c <- data["equipment"] do
  component = if c["stored"], do: "minecraft:stored_enchantments", else: "minecraft:enchantments"

  stack = %{
    ItemStack.new("stone")
    | components: %{component => %{c["enchantment"] => c["level"]}}
  }

  inventory = %Inventory{slots: %{c["slot"] => stack}}

  unless Armor.oxygen_bonus(Armor.equipment(inventory)) == c["oxygen"],
    do: raise("Native oxygen equipment differs #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(data["cases"])} native air primitives and #{length(data["equipment"])} oxygen equipment cases."
)
