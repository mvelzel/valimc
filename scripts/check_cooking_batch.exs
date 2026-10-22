[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Blocks.Cooking
alias Valimc.Blocks.CookingBlocks
alias Valimc.Protocol.ItemStack
alias Valimc.World.{Containers, CookingBatch, CookingRuntime}
alias Valimc.Entity.Store

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

for row <- raw["cases"] do
  before = row["before"]
  block = before["state"]

  entry = %{
    kind: CookingBlocks.kind(block),
    revision: 1,
    cooking: state.(before),
    recipes: before["recipes"]
  }

  containers = %Containers{sequence: 1, entries: %{position => entry}}

  {:ok, result} =
    CookingRuntime.plan(
      containers,
      Store.new(),
      {0, 0},
      %{position => block},
      :all,
      MapSet.new()
    )

  true = result.refused == %{}
  true = CookingBatch.awake?(entry, block) == (before != row["after"])
  actual = result.containers.entries[position]
  true = actual.cooking == state.(row["after"]) and actual.recipes == row["after"]["recipes"]
  true = Map.get(result.changes, position, block) == row["after"]["state"]
  true = Enum.map(Store.records(result.items), & &1.stack) == Enum.map(row["drops"], stack)
  content_changed = entry.cooking.slots != actual.cooking.slots or entry.recipes != actual.recipes
  true = actual.revision == if(content_changed, do: 2, else: 1)

  true =
    MapSet.member?(result.active, position) == CookingBatch.awake?(actual, row["after"]["state"])

  true = result.content == if(content_changed, do: [position], else: [])
  true = result.batch != nil == (before["state"] != row["after"]["state"])
end

IO.puts(
  "PASS:15,630 native cooking states through runtime activity selection, recipe uses, lit frames, remainders and content-only revisions."
)
