alias Valimc.Player.Use
alias Valimc.Protocol.{Data, EntityPackets, ItemStack, Packets, UseItem, Wire}
[input, output] = System.argv()
data = input |> File.read!() |> JSON.decode!()

requests =
  for c <- data["requests"] do
    {:ok, value} = UseItem.decode(Base.decode16!(c["wire"], case: :mixed))

    unless value.hand == String.to_existing_atom(c["hand"]) and value.sequence == c["sequence"] and
             value.yaw == c["yaw"] and value.pitch == c["pitch"],
           do: raise("Native use request differs #{inspect(c)}")

    bytes =
      IO.iodata_to_binary([
        Wire.varint(if(value.hand == :main, do: 0, else: 1)),
        Wire.varint(value.sequence),
        <<value.yaw::float-32, value.pitch::float-32>>
      ])

    wire = Base.encode16(bytes, case: :lower)
    unless wire == c["wire"], do: raise("Native use bytes differ #{inspect(c)}")
    %{"name" => c["name"], "wire" => wire}
  end

metadata =
  for c <- data["metadata"] do
    {id, body} = EntityPackets.metadata(c["entity_id"], living_flags: c["flags"])

    unless id == Data.id(:play, :clientbound, "set_entity_data"),
      do: raise("Wrong living metadata packet")

    wire = body |> IO.iodata_to_binary() |> Base.encode16(case: :lower)
    unless wire == c["wire"], do: raise("Native living flags differ #{inspect(c)}")
    %{"entity_id" => c["entity_id"], "flags" => c["flags"], "wire" => wire}
  end

for c <- data["ticks"] do
  hand = String.to_existing_atom(c["hand"])

  use =
    Use.new(ItemStack.new("stone", 2), hand, %{consumable: %{"ticks" => c["remaining"]}})

  current =
    case c["change"] do
      "empty" ->
        nil

      "type" ->
        ItemStack.new("dirt")

      "components" ->
        %{
          ItemStack.new("stone")
          | components: %{
              "minecraft:food" => %{nutrition: 1, saturation: 1.0, can_always_eat: false}
            }
        }

      _ ->
        ItemStack.new("stone")
    end

  {status, next} = Use.tick(use, current)

  unless status == :cancel == (c["stopped"] == 1) and status == :finish == (c["completed"] == 1) and
           status == :using == c["active"],
         do: raise("Native use clock differs #{inspect({c, status})}")

  if next && next.remaining != c["next"],
    do: raise("Native remaining use ticks differ #{inspect(c)}")
end

events =
  for c <- data["events"] do
    {id, body} = Packets.use_item_finished(c["entity_id"])
    unless id == Data.id(:play, :clientbound, "entity_event"), do: raise("Wrong use event")
    wire = body |> IO.iodata_to_binary() |> Base.encode16(case: :lower)
    unless wire == c["wire"], do: raise("Native use completion differs #{inspect(c)}")
    %{"entity_id" => c["entity_id"], "wire" => wire}
  end

File.write!(
  output,
  JSON.encode!(%{"requests" => requests, "metadata" => metadata, "events" => events})
)

IO.puts(
  "PASS: #{length(requests)} native use requests, #{length(metadata)} flag packets and #{length(data["ticks"])} active-use tick prefixes."
)
