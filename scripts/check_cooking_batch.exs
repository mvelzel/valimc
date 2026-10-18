[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Cooking
alias Valimc.Physics.CookingBlocks
alias Valimc.Protocol.ItemStack
alias Valimc.World.{Containers, CookingBatch, Items}

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
    length(raw["cases"]) == 15_630

stack = fn hex ->
  {:ok, value} = ItemStack.decode(Base.decode16!(hex, case: :lower))
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

position = {4, 64, 4}
receipts = %{<<1::128>> => %{sequence: 77, digest: <<2::256>>}}

for row <- raw["cases"] do
  before = row["before"]
  block = before["state"]

  entry = %{
    kind: CookingBlocks.kind(block),
    revision: 1,
    cooking: state.(before),
    recipes: before["recipes"]
  }

  containers = %Containers{sequence: 1, entries: %{position => entry}, receipts: receipts}
  {:ok, result} = CookingBatch.plan(containers, Items.new(), {0, 0}, %{position => block})
  true = result.refused == %{}
  true = CookingBatch.awake?(entry, block) == (before != row["after"])
  actual = result.containers.entries[position]
  true = actual.cooking == state.(row["after"]) and actual.recipes == row["after"]["recipes"]
  true = Map.get(result.changes, position, block) == row["after"]["state"]
  true = Enum.map(Items.records(result.items), & &1.stack) == Enum.map(row["drops"], stack)
  true = result.containers.receipts == receipts
  content_changed = entry.cooking.slots != actual.cooking.slots or entry.recipes != actual.recipes
  true = actual.revision == if(content_changed, do: 2, else: 1)
end

IO.puts(
  "PASS:15,630 native cooking states composed with exact recipe uses, lit states, remainder quantities, preserved receipts and content-only revision fencing."
)
