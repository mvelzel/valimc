[path] = System.argv()
raw = JSON.decode!(File.read!(path))
alias Valimc.Protocol.ChestSounds
facts = JSON.decode!(File.read!("priv/protocol/chest_sounds.json"))
true = raw["version"] == "26.3" and raw["server_sha1"] == facts["server_sha1"]
true = raw["blocks_source"] == facts["blocks_source"]
true = Map.new(raw["registry"], &{&1["name"], &1["id"]}) == facts["sounds"]
true = Enum.all?(raw["registry"], &(&1["range"] == 16.0))
true = length(raw["traces"]) == 256 and length(raw["packets"]) == 270

for trace <- raw["traces"], {draw, sound} <- Enum.zip(trace["draws"], trace["sounds"]) do
  {:ok, pitch} = ChestSounds.pitch(draw)
  true = <<pitch::float-32>> == <<sound["pitch"]::float-32>>
  true = sound["volume"] == 0.5 and sound["at"] == [-0.5, 64.5, 15.5]
end

compared =
  for row <- raw["packets"],
      row["volume"] == 0.5,
      row["pitch"] >= 0.89 and row["pitch"] <= 1,
      Enum.all?(row["position"], &(floor(&1) + 0.5 == &1)) do
    position = row["position"] |> Enum.map(&floor/1) |> List.to_tuple()
    draw = if row["pitch"] == 1, do: 16_777_215 / 16_777_216, else: 0.0

    {:ok, {_id, body}} =
      ChestSounds.packet(
        row["sound"] == "minecraft:block.chest.open",
        position,
        draw,
        row["seed"]
      )

    true = IO.iodata_to_binary(body) == Base.decode16!(row["hex"], case: :lower)
    row
  end

true = length(compared) == 40

IO.puts(
  "PASS: 512 actual chest pitch calls and 40 supported registered chest sound bodies from 270 codec contexts; no runtime delivery claim."
)

for row <- raw["halves"] do
  case Valimc.Blocks.Chest.sound_position(row["state"], {-1, 64, 15}) do
    nil ->
      true = row["sounds"] == []

    {x, y, z} ->
      true = length(row["sounds"]) == 2
      for sound <- row["sounds"], do: true = sound["at"] == [x + 0.5, y + 0.5, z + 0.5]
  end
end

IO.puts("PASS: 24 native chest-half sound locations and suppression traces")
