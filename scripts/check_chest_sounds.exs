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

barrels = raw["barrels"]
true = length(barrels) == 12 and length(raw["barrel_packets"]) == 48

for row <- barrels do
  state = row["state"]
  position = {-1, 64, 15}
  {x, y, z} = Valimc.Blocks.Barrel.sound_at(state, position)
  true = Valimc.Blocks.block_entity(state) == :barrel

  true =
    row["states"] ==
      [Valimc.Blocks.Barrel.with_open(state, true), Valimc.Blocks.Barrel.with_open(state, false)]

  true =
    Enum.map(row["sounds"], & &1["sound"]) == [
      "minecraft:block.barrel.open",
      "minecraft:block.barrel.close"
    ]

  for {draw, sound} <- Enum.zip(row["draws"], row["sounds"]) do
    {:ok, pitch} = ChestSounds.pitch(draw)
    true = <<pitch::float-32>> == <<sound["pitch"]::float-32>>
    true = sound["volume"] == 0.5 and sound["at"] == [x, y, z]
  end
end

for row <- raw["barrel_packets"] do
  draw = if row["pitch"] == 1, do: 16_777_215 / 16_777_216, else: 0.0
  at = List.to_tuple(row["position"])

  {:ok, {_id, body}} =
    ChestSounds.barrel_packet(
      row["sound"] == "minecraft:block.barrel.open",
      at,
      draw,
      row["seed"]
    )

  true = IO.iodata_to_binary(body) == Base.decode16!(row["hex"], case: :lower)
end

IO.puts(
  "PASS: 12 native barrel open-state/sound traces (first and last of three viewers, spectator silent) and 48 barrel sound bodies"
)

# Shulker boxes (VMC-032c2): vanilla sends block event 1 with the opener count
# for every viewer that is not a spectator; ValiMC sends the first opening and
# the last closing (all the lid's movement reads) for the box's own block id.
shulkers = raw["shulker_boxes"]
true = length(shulkers) == 12

for row <- shulkers do
  state = row["state"]
  position = {-1, 64, 15}
  block = Valimc.Data.Blocks.block_id(state)
  true = Valimc.Blocks.block_entity(state) == :shulker_box
  true = row["events"] == [[block, 1, 1], [block, 1, 2], [block, 1, 1], [block, 1, 0]]

  for {open, [_, b0, b1]} <- [{true, hd(row["events"])}, {false, List.last(row["events"])}] do
    {_, ours} = Valimc.Blocks.ShulkerBox.lid_event(state, position, open)
    {_, native} = Valimc.Protocol.Packets.block_event(position, b0, b1, block)
    true = IO.iodata_to_binary(ours) == IO.iodata_to_binary(native)
  end

  true =
    Enum.map(row["sounds"], &{&1["sound"], &1["after_events"]}) == [
      {"minecraft:block.shulker_box.open", 1},
      {"minecraft:block.shulker_box.close", 4}
    ]

  for {draw, sound} <- Enum.zip(row["draws"], row["sounds"]) do
    {:ok, pitch} = ChestSounds.pitch(draw)
    true = <<pitch::float-32>> == <<sound["pitch"]::float-32>>
    true = sound["volume"] == 0.5 and sound["at"] == [-0.5, 64.5, 15.5]
  end
end

IO.puts(
  "PASS: 12 native shulker box lid event/sound traces (first and last of three viewers, spectator silent) for the box's own block id"
)

# Ender chests (VMC-032c3): the same viewer counting for the ender chest's own
# block id, `block.ender_chest.open`/`close` at the centre; ValiMC sends the
# first opening and the last closing.
enders = raw["ender_chests"]
true = length(enders) == 8 and length(raw["ender_packets"]) == 36

for row <- enders do
  state = row["state"]
  position = {-1, 64, 15}
  block = Valimc.Data.Blocks.block_id(state)
  true = Valimc.Blocks.EnderChest.ender_chest?(state)
  true = row["events"] == [[block, 1, 1], [block, 1, 2], [block, 1, 1], [block, 1, 0]]

  for {open, [_, b0, b1]} <- [{true, hd(row["events"])}, {false, List.last(row["events"])}] do
    {_, ours} = Valimc.Blocks.EnderChest.lid_event(position, open)
    {_, native} = Valimc.Protocol.Packets.block_event(position, b0, b1, block)
    true = IO.iodata_to_binary(ours) == IO.iodata_to_binary(native)
  end

  # `ContainerOpenersCounter` sounds before the count's event (`onOpen`,
  # `onClose`); ValiMC publishes the event and the sound together.
  true =
    Enum.map(row["sounds"], &{&1["sound"], &1["after_events"]}) == [
      {"minecraft:block.ender_chest.open", 0},
      {"minecraft:block.ender_chest.close", 3}
    ]

  for {draw, sound} <- Enum.zip(row["draws"], row["sounds"]) do
    {:ok, pitch} = ChestSounds.pitch(draw)
    true = <<pitch::float-32>> == <<sound["pitch"]::float-32>>
    true = sound["volume"] == 0.5 and sound["at"] == [-0.5, 64.5, 15.5]
  end
end

for row <- raw["ender_packets"] do
  draw = if row["pitch"] == 1, do: 16_777_215 / 16_777_216, else: 0.0
  cell = row["position"] |> Enum.map(&floor/1) |> List.to_tuple()

  {:ok, {_id, body}} =
    ChestSounds.packet(
      row["sound"] == "minecraft:block.ender_chest.open",
      cell,
      draw,
      row["seed"],
      :ender_chest
    )

  true = IO.iodata_to_binary(body) == Base.decode16!(row["hex"], case: :lower)
end

IO.puts(
  "PASS: 8 native ender chest lid event/sound traces (first and last of three viewers, spectator silent) and 36 ender chest sound bodies"
)
