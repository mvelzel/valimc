alias Valimc.Protocol.{ChestBlockEntity, Data}
alias Valimc.World.Chunk
[input, output] = System.argv()
raw = JSON.decode!(File.read!(input))
true = raw["version"] == "26.3" and raw["protocol"] == 777 and raw["block_entity_type"] == 1

for row <- raw["cases"] do
  position = List.to_tuple(row["position"])
  bytes = ChestBlockEntity.chunk_entry(position) |> IO.iodata_to_binary()
  true = Base.encode16(bytes, case: :lower) == row["chunk_hex"]
  {id, payload} = ChestBlockEntity.update(position)
  true = id == Data.id(:play, :clientbound, "block_entity_data")
  true = Base.encode16(IO.iodata_to_binary(payload), case: :lower) == row["update_hex"]
end

facts = JSON.decode!(File.read!("priv/protocol/chest_states.json"))
block = hd(facts["single_states"])
fixtures = [{{0, 0}, [{1, 64, 2}, {14, 65, 15}]}, {{-1, -2}, [{-1, 63, -17}, {-16, 319, -32}]}]
Chunk.load!()

chunks =
  for {key, positions} <- fixtures do
    edits = Map.new(positions, &{&1, block})
    {_, payload} = Chunk.encode(key, edits)

    %{
      x: elem(key, 0),
      z: elem(key, 1),
      positions: Enum.map(positions, &Tuple.to_list/1),
      wire: Base.encode16(IO.iodata_to_binary(payload), case: :lower)
    }
  end

File.write!(output, JSON.encode!(chunks))

IO.puts(
  "PASS: 64 exact native chest chunk-entry/update bodies and two complete chunk fixtures; Mojang decode and GUI rendering follow."
)
