alias Valimc.Living.Effects
[facts_path, path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()
pinned = "priv/protocol/consume_status.json" |> File.read!() |> JSON.decode!()

unless facts == pinned, do: raise("Pinned stock food callbacks differ")

rows = path |> File.read!() |> JSON.decode!()

for row <- rows do
  expected = Enum.map(row["expected_effects"], &{&1["id"], [List.to_tuple(&1["rung"])]})
  callbacks = [%{probability: row["probability"], effects: expected}]
  {:ok, selected} = Effects.food_effects(callbacks, [row["draw"]])
  actual = Enum.map(row["calls"], &{&1["id"], [List.to_tuple(&1["rung"])]})

  unless selected == actual and row["draws"] == 1 and
           row["changed"] == (row["accepts"] and actual != []),
         do: raise("Native consume-status callback differs #{inspect(row)}: #{inspect(selected)}")
end

IO.puts(
  "PASS: #{length(facts["items"])} pinned stock food callback facts and #{length(rows)} native group/chance/order cases; live food/consumption excluded."
)
