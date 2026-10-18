[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Physics.CookingItems
alias Valimc.Protocol.{Data, ItemStack}

true =
  raw["version"] == "26.3" and raw["data_version"] == 5023 and
    raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["completion"]) == 37_440 and length(raw["consumption"]) == 1_960

stack = fn hex ->
  {:ok, value} = ItemStack.decode(Base.decode16!(hex, case: :lower))
  value
end

for row <- raw["completion"] do
  before = row["before"] |> Enum.map(stack) |> List.to_tuple()
  result = stack.(row["result"])
  expected = row["after"] |> Enum.map(stack) |> List.to_tuple()

  case CookingItems.finish(before, result, row["limit"]) do
    {:ok, after_slots} -> true = row["allowed"] and after_slots == expected
    {:error, :output_full} -> true = not row["allowed"] and expected == before
    other -> raise("Cooking completion mismatch: #{inspect({row, other})}")
  end
end

state = Data.item_block(Data.item("furnace"))

for row <- raw["consumption"] do
  {:ok, result} = CookingItems.consume_fuel(stack.(row["before"]), state)
  true = result.fuel == stack.(row["after"]) and result.drops == Enum.map(row["drops"], stack)
end

IO.puts(
  "PASS: 37,440 actual native canBurn/burn slot transitions and1,960 fuel consumption/remainder callbacks; no recipe/timer/runtime claim."
)
