alias Valimc.Blocks.Cooking
alias Valimc.Menus.{Inventory, Menu}
alias Valimc.Protocol.{ItemStack, Packets}
[path] = System.argv()
facts = JSON.decode!(File.read!(path))

true =
  facts["version"] == "26.3" and facts["protocol"] == 777 and
    facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = Enum.map(facts["cases"], & &1["kind"]) == [0, 1, 2] and length(facts["progress"]) == 180
kinds = {:furnace, :smoker, :blast_furnace}

stack = fn
  nil -> nil
  [id, count, nil, nil] -> %ItemStack{item_id: id, count: count}
end

for row <- facts["cases"] do
  kind = elem(kinds, row["kind"])
  {:ok, type} = Menu.cooking_type(kind)
  true = type == row["type"] and length(row["slots"]) == 39

  for {[owner, index], wire} <- Enum.with_index(row["slots"]) do
    expected = if owner == "cooking", do: {:cooking, index}, else: index
    {:ok, ^expected} = Menu.address(Menu.cooking(nil), wire)
  end

  slots =
    for {item, slot} <- Enum.with_index(row["player"]),
        item != nil,
        into: %{},
        do: {slot, stack.(item)}

  cooking = %Cooking{slots: row["storage"] |> Enum.map(stack) |> List.to_tuple()}
  inventory = %Inventory{slots: slots}
  {:ok, contents} = Menu.cooking_contents(cooking, inventory)
  true = contents == Enum.map(row["contents"], stack) and row["after_close"] == row["storage"]
  {_, body} = Packets.open_cooking(17, kind)
  true = IO.iodata_to_binary(body) == Base.decode16!(row["open_hex"], case: :lower)
  {_, body} = Packets.cooking_inventory(17, cooking, inventory)
  true = IO.iodata_to_binary(body) == Base.decode16!(row["content_hex"], case: :lower)
end

for row <- facts["progress"] do
  cooking = %Cooking{
    burn_left: row["burn_left"],
    burn_total: row["burn_total"],
    progress: row["progress"],
    total: row["total"]
  }

  {:ok, actual} = Menu.properties(cooking)
  true = actual == row["data"]
  bodies = for {_, body} <- Packets.cooking_properties(17, cooking), do: IO.iodata_to_binary(body)
  true = bodies == Enum.map(row["data_hex"], &Base.decode16!(&1, case: :lower))
end

IO.puts(
  "PASS:3 native cooking menus/117 addresses/open/content bodies, storage-preserving close and180 progress contexts/720 exact property bodies. Live admission/clicks/ticking/XP remain separate."
)
