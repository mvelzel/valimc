[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Blocks.Cooking
alias Valimc.Protocol.ItemStack

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["cases"]) == 15_630

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

Enum.reduce(raw["cases"], %{}, fn row, traces ->
  trace = row["trace"]

  if trace != nil and row["tick"] > 0 and not row["external_edit"] do
    true = Map.fetch!(traces, trace) == row["before"]
  end

  before = state.(row["before"])
  expected = state.(row["after"])
  {:ok, after_state, events} = Cooking.step(before, row["before"]["state"])

  used =
    if events.completed,
      do: Map.update(row["before"]["recipes"], events.completed, 1, &(&1 + 1)),
      else: row["before"]["recipes"]

  true = used == row["after"]["recipes"]

  unless after_state == expected and events.drops == Enum.map(row["drops"], stack) do
    raise("Cooking tick mismatch: #{inspect({row, after_state, events})}")
  end

  true = events.lit == expected.burn_left > 0
  true = events.lit == row["after"]["lit"]
  if trace == nil, do: traces, else: Map.put(traces, trace, row["after"])
end)

IO.puts(
  "PASS: 2,880 native boundaries and12,750 actual multi-tick furnace progress/fuel/completion/cooldown steps; runtime journal and menus remain unadmitted."
)
