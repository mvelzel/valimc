import Bitwise
alias Valimc.Data.EffectTypes
alias Valimc.Protocol.{Packets, Wire}
[facts_path, path, output] = System.argv()
facts = :json.decode(File.read!(facts_path))

unless facts == :json.decode(File.read!("priv/protocol/status_effects.json")),
  do: raise("Native effect identities differ")

for {name, id} <- Enum.with_index(facts["effects"]) do
  unless EffectTypes.name(id) == name and EffectTypes.id(name) == id,
    do: raise("Native effect index differs")
end

rows = :json.decode(File.read!(path))

encoded =
  for row <- rows do
    packet =
      case row["kind"] do
        "remove" ->
          Packets.remove_effect(row["entity"], row["effect"])

        "update" ->
          flags = row["flags"]

          rung =
            {row["ticks"], row["level"], (flags &&& 1) != 0, (flags &&& 2) != 0,
             (flags &&& 4) != 0}

          Packets.update_effect(row["entity"], row["effect"], rung, (flags &&& 8) != 0)
      end

    {id, body} = packet
    wire = IO.iodata_to_binary([Wire.varint(id), body]) |> Base.encode16(case: :lower)
    unless wire == row["wire"], do: raise("Native effect packet differs: #{inspect({row, wire})}")
    Map.put(row, "wire", wire)
  end

File.write!(output, :json.encode(encoded))

IO.puts(
  "PASS: #{length(rows)} complete status packets and all#{EffectTypes.count()} native effect identities. No live effects claimed."
)
