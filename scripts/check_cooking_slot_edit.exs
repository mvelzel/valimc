alias Valimc.Cooking
alias Valimc.CookingBlocks
alias Valimc.Protocol.ItemStack
[path] = System.argv()
facts = JSON.decode!(File.read!(path))

true =
  facts["version"] == "26.3" and
    facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(facts["cases"]) == 2_304

stack = fn hex ->
  {:ok, value, <<>>} = ItemStack.take(Base.decode16!(hex, case: :lower))
  value
end

state = fn row ->
  %Cooking{
    slots: row["slots"] |> Enum.map(stack) |> List.to_tuple(),
    burn_left: row["litTimeRemaining"],
    burn_total: row["litTotalTime"],
    progress: row["cookingTimer"],
    total: row["cookingTotalTime"],
    speed: row["speed"]
  }
end

kinds = {:furnace, :smoker, :blast_furnace}

for row <- facts["cases"] do
  before = state.(row["before"])
  slots = put_elem(before.slots, row["slot"], stack.(row["replacement"]))
  {:ok, block} = CookingBlocks.placement(elem(kinds, row["kind"]), 0.0)
  {:ok, actual} = Cooking.edit_slots(before, slots, block)
  expected = state.(row["after"])

  unless actual == expected,
    do: raise("Native external slot edit differs: #{inspect(row)} ACTUAL #{inspect(actual)}")
end

IO.puts(
  "PASS:2304 native changed-slot assignments, count/identity/clear/fuel/output and contextual duration boundaries; no journal/live caller/XP claim."
)
