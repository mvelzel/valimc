alias Valimc.Living.{Armor, Freezing}
alias Valimc.Player.GameMode
alias Valimc.Menus.Inventory
alias Valimc.Protocol.ItemStack
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
unless data["required"] == 140, do: raise("Native freeze threshold changed")

for c <- data["equipment"] do
  spectator = GameMode.new(String.to_existing_atom(c["mode"])).current == :spectator
  inventory = %Inventory{slots: %{c["slot"] => %ItemStack{item_id: c["item_id"]}}}

  unless Freezing.can_freeze?(spectator, Armor.equipment(inventory)) == c["allowed"],
    do: raise("Native freeze eligibility differs #{inspect(c)}")
end

for c <- data["thresholds"] do
  unless c["ticks"] >= 140 == c["fully"], do: raise("Native full-freeze boundary differs")
end

IO.puts(
  "PASS: #{length(data["equipment"])} native player freeze eligibility cases and full-freeze boundary."
)
