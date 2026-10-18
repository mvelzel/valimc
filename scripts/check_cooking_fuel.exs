[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Physics.CookingFuel
alias Valimc.Protocol.ItemStack

true =
  raw["version"] == "26.3" and raw["data_version"] == 5023 and
    raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["callbacks"]) == 79_584

for row <- raw["callbacks"] do
  stack =
    if row["item"] == 0 do
      nil
    else
      %ItemStack{
        item_id: row["item"],
        removed:
          if(row["removed"], do: MapSet.new(["minecraft:cooking_fuel"]), else: MapSet.new())
      }
    end

  {:ok, result} = CookingFuel.resolve(stack, row["state"])
  true = result.burn_ticks == row["burn"] and result.speed_multiplier == row["speed"]
end

IO.puts(
  "PASS: all 79,584 actual native stock/removed cooking-fuel callbacks over 1,658 items and24 furnace states; consumption/cooking/menu/XP remain unadmitted."
)
