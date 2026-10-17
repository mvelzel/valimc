alias Valimc.{ChestMenu, Inventory}
alias Valimc.Protocol.{ItemStack, Packets}
[path] = System.argv()
facts = JSON.decode!(File.read!(path))

unless facts["version"] == "26.3" and facts["protocol"] == 777 and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c",
       do: raise("Wrong native chest reference")

unless Enum.map(facts["cases"], & &1["rows"]) == Enum.to_list(1..6),
  do: raise("Incomplete native chest layouts")

stack = fn
  nil -> nil
  [id, count, nil, nil] -> %ItemStack{item_id: id, count: count}
end

for row <- facts["cases"] do
  rows = row["rows"]

  unless length(row["slots"]) == rows * 9 + 36 and length(row["storage"]) == rows * 9,
    do: raise("Incomplete native chest cells")

  {:ok, type} = ChestMenu.type(rows)
  unless type == row["type"], do: raise("Native chest menu type differs")

  for {[kind, index], wire} <- Enum.with_index(row["slots"]) do
    expected = if kind == "container", do: {:container, index}, else: index
    {:ok, ^expected} = ChestMenu.address(rows, wire)
  end

  storage = row["storage"] |> Enum.map(stack) |> List.to_tuple()

  slots =
    for {item, slot} <- Enum.with_index(row["player"]),
        item != nil,
        into: %{},
        do: {slot, stack.(item)}

  {:ok, contents} = ChestMenu.contents(rows, storage, %Inventory{slots: slots})
  unless contents == Enum.map(row["contents"], stack), do: raise("Native chest contents differ")
  {_, body} = Packets.open_chest(17, rows)

  unless IO.iodata_to_binary(body) == Base.decode16!(row["open_hex"], case: :lower),
    do: raise("Native chest open body differs")

  unless row["opens"] == 1 and row["closes"] == 1 and row["after_close"] == row["storage"],
    do: raise("Native chest close/lifecycle differs")
end

IO.puts(
  "PASS: six native chest layouts/405 slot identities, open bodies and contents; empty-cursor close retains storage. Shared authority/clicks/world/persistence not implemented."
)
