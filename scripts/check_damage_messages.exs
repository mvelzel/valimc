alias Valimc.Living.DamageSource
alias Valimc.Protocol.{Packets, Wire}
[facts_path, path, output] = System.argv()

unless :json.decode(File.read!(facts_path)) ==
         :json.decode(File.read!("priv/protocol/damage_messages.json")),
       do: raise("Native death-message facts differ")

cases = :json.decode(File.read!(path))

rows =
  for row <- cases, entity <- [1, 127, 128, 2_147_483_647], kind <- ["death", "chat"] do
    source = String.to_atom(row["source"])
    message = DamageSource.death_message(row["name"], source)
    {:compound, %{"translate" => {:string, key}, "with" => {:list, {:string, names}}}} = message

    unless key == row["message"]["translate"] and names == row["message"]["with"],
      do: raise("Native death translation differs")

    {id, body} =
      if kind == "death", do: Packets.death(entity, message), else: Packets.chat(message)

    wire = IO.iodata_to_binary([Wire.varint(id), body]) |> Base.encode16(case: :lower)
    row |> Map.drop(["message"]) |> Map.merge(%{entity: entity, kind: kind, wire: wire})
  end

File.write!(output, :json.encode(rows))

IO.puts(
  "PASS: #{length(rows)} source-specific death/chat packet components ready for native decoding."
)
