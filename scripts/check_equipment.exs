alias Valimc.Protocol.{Data, EntityPackets, ItemStack}
[input, output] = System.argv()
rows = input |> File.read!() |> JSON.decode!()

encoded =
  for row <- rows do
    changes =
      for slot <- row["slots"] do
        stack =
          if slot["count"] > 0 do
            stack = %ItemStack{item_id: slot["item_id"], count: slot["count"]}

            if slot["glint"],
              do: %{stack | components: %{"minecraft:enchantment_glint_override" => true}},
              else: stack
          end

        {slot["slot"], stack}
      end

    {id, body} = EntityPackets.equipment(row["entity_id"], changes)

    unless id == Data.id(:play, :clientbound, "set_equipment"),
      do: raise("Wrong equipment packet")

    wire = body |> IO.iodata_to_binary() |> Base.encode16(case: :lower)
    unless wire == row["wire"], do: raise("Equipment codec differs #{row["name"]}")
    %{"name" => row["name"], "wire" => wire}
  end

File.write!(output, JSON.encode!(encoded))

IO.puts(
  "PASS: #{length(encoded)} native equipment packets, including empty/patched stacks and continuation batches."
)
