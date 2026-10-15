alias Valimc.{Inventory, PlayerAir}
alias Valimc.Protocol.ItemStack
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
unless data["maximum"] == PlayerAir.maximum(), do: raise("Native air maximum changed")

for c <- data["cases"] do
  unless PlayerAir.decrease(c["air"], c["oxygen"], c["draw"]) == c["decrease"] and
           PlayerAir.increase(c["air"]) == c["increase"] and
           PlayerAir.drowning?(c["air"]) == c["drowning"],
         do: raise("Native air primitive differs #{inspect(c)}")
end

for c <- data["equipment"] do
  component = if c["stored"], do: "minecraft:stored_enchantments", else: "minecraft:enchantments"

  stack = %{
    ItemStack.new("stone")
    | components: %{component => %{c["enchantment"] => c["level"]}}
  }

  inventory = %Inventory{slots: %{c["slot"] => stack}}

  unless PlayerAir.oxygen_bonus(inventory) == c["oxygen"],
    do: raise("Native oxygen equipment differs #{inspect(c)}")
end

IO.puts(
  "PASS: #{length(data["cases"])} native air primitives and #{length(data["equipment"])} oxygen equipment cases."
)
