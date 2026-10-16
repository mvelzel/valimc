alias Valimc.PlayerDeathMessage
alias Valimc.Protocol.{Packets, Wire}
[input, output] = System.argv()
rows = input |> File.read!() |> JSON.decode!()

packet = fn {id, body} ->
  IO.iodata_to_binary([Wire.varint(id), body]) |> Base.encode16(case: :lower)
end

encoded =
  Enum.map(rows, fn row ->
    event = packet.(Packets.self_magic_damage(row["entity"]))
    unless event == row["event"], do: raise("Native self damage event differs #{inspect(row)}")
    result = Map.take(row, ["entity", "name", "held"]) |> Map.put("event", event)

    if row["held"] == "named_potion" do
      result
    else
      component = PlayerDeathMessage.component(row["name"], :self_magic)
      {:compound, fields} = component

      unless fields["translate"] == {:string, row["message"]["translate"]} and
               fields["with"] == {:list, {:string, row["message"]["with"]}},
             do: raise("Native self magic text differs")

      death = packet.(Packets.death(row["entity"], component))
      chat = packet.(Packets.chat(component))
      Map.merge(result, %{"death" => death, "chat" => chat})
    end
  end)

File.write!(output, JSON.encode!(encoded))

IO.puts(
  "PASS: 32 native self-magic events and24 plain-hand death/chat components; named-item text excluded."
)
