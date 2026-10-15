alias Valimc.Physics.MiningTools
alias Valimc.Protocol.ItemStack
[facts_path, cases_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()
committed = "priv/physics/mining_tools.json" |> File.read!() |> JSON.decode!()
unless facts == committed, do: raise("Native mining tool catalog differs")
cases = cases_path |> File.read!() |> JSON.decode!()

for row <- cases["profiles"] do
  stack = %ItemStack{item_id: row["item"]}
  expected_speed = Base.decode16!(row["speed_bits"], case: :lower)
  expected_correct = Base.decode16!(row["correct"], case: :lower)

  speed =
    for state <- 0..(facts["state_count"] - 1), into: <<>> do
      <<MiningTools.speed(stack, state)::float-32>>
    end

  correct =
    for state <- 0..(facts["state_count"] - 1), into: <<>> do
      <<if(MiningTools.correct_tool?(stack, state), do: 1, else: 0)>>
    end

  unless speed == expected_speed and correct == expected_correct,
    do:
      raise(
        "Native mining tool state results differ: #{inspect(Map.take(row, ["profile", "item"]))}"
      )

  for {creative, expected} <- Enum.zip([false, true], row["can_destroy"]),
      do:
        unless(MiningTools.can_destroy?(stack, creative) == expected,
          do: raise("Native destruction differs")
        )
end

for row <- cases["permissions"] do
  stock = %ItemStack{item_id: row["item"]}
  removed = %{stock | removed: MapSet.new(["minecraft:tool"])}
  removed_permission = row["item"] not in facts["blocked_items"]

  for {creative, expected} <- Enum.zip([false, true], row["stock"]),
      do:
        unless(MiningTools.can_destroy?(stock, creative) == expected,
          do: raise("Native item permission differs")
        )

  for name <- ["stone", "cobweb"] do
    state = Valimc.Protocol.Data.item_block(Valimc.Protocol.Data.item(name))

    unless MiningTools.speed(removed, state) == 1.0 and
             not MiningTools.correct_tool?(removed, state) and
             MiningTools.can_destroy?(removed, false) == removed_permission and
             MiningTools.can_destroy?(removed, true) == removed_permission,
           do: raise("Native absent-tool behavior differs")
  end
end

IO.puts(
  "PASS: #{length(cases["profiles"]) * facts["state_count"]} bit-exact native stock tool state pairs, #{length(cases["permissions"])} item permissions and removed-tool controls."
)
