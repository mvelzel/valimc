alias Valimc.PlayerDeathMessage
alias Valimc.Protocol.{ItemData, ItemStack, Packets, Wire}
alias Valimc.NBT
[input, output] = System.argv()
rows = input |> File.read!() |> JSON.decode!()

packet = fn {id, body} ->
  IO.iodata_to_binary([Wire.varint(id), body]) |> Base.encode16(case: :lower)
end

encoded =
  Enum.map(rows, fn row ->
    {:ok, stack} = row["stack"] |> Base.decode16!(case: :lower) |> ItemStack.decode()
    data = stack |> ItemData.tag() |> NBT.encode_server_component() |> IO.iodata_to_binary()
    death = PlayerDeathMessage.component("ValiMCTest", {:self_magic, stack})
    death_packet = packet.(Packets.death(1, death))
    chat_packet = packet.(Packets.chat(death))
    death = death |> Wire.text_component() |> IO.iodata_to_binary()

    %{
      "name" => row["name"],
      "data" => Base.encode16(data, case: :lower),
      "death" => Base.encode16(death, case: :lower),
      "death_packet" => death_packet,
      "chat_packet" => chat_packet
    }
  end)

File.write!(output, JSON.encode!(encoded))

IO.puts(
  "PASS: #{length(encoded)} bounded item data and original-mainhand death hover candidates encoded."
)
