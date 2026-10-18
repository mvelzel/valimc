[input] = System.argv()
raw = JSON.decode!(File.read!(input))

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = raw["chest_block_id"] == 245 and length(raw["cases"]) == 8 and length(raw["packets"]) == 18

for row <- raw["cases"] do
  true = row["counts"] == [1, 1, 2, 2, 1, 0]
  true = row["events"] == [[1, 1], [1, 2], [1, 1], [1, 0]]
  true = row["openness"] == [0.5, 1.0, 0.0]

  true =
    Enum.map(row["sounds"], & &1["sound"]) == [
      "minecraft:block.chest.open",
      "minecraft:block.chest.close"
    ]
end

for row <- raw["packets"], row["requested"] in [0, 1] do
  {_, body} =
    Valimc.Protocol.Packets.chest_lid(List.to_tuple(row["position"]), row["requested"] == 1)

  true = IO.iodata_to_binary(body) == Base.decode16!(row["hex"], case: :lower)
end

IO.puts(
  "PASS: eight native viewer/lid traces and six binary-occupancy event bodies; runtime registration and sound delivery are separate gates."
)
