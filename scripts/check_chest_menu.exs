alias Valimc.Menus.{Inventory, Menu}
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

  {:ok, type} = Menu.type(Menu.chest(rows))
  unless type == row["type"], do: raise("Native chest menu type differs")

  for {[kind, index], wire} <- Enum.with_index(row["slots"]) do
    expected = if kind == "container", do: {:container, index}, else: index
    {:ok, ^expected} = Menu.address(Menu.chest(rows), wire)
  end

  storage = row["storage"] |> Enum.map(stack) |> List.to_tuple()

  slots =
    for {item, slot} <- Enum.with_index(row["player"]),
        item != nil,
        into: %{},
        do: {slot, stack.(item)}

  {:ok, contents} = Menu.contents(Menu.chest(rows), storage, %Inventory{slots: slots})
  unless contents == Enum.map(row["contents"], stack), do: raise("Native chest contents differ")
  {_, body} = Valimc.Menus.Packets.open_chest(17, rows)

  unless IO.iodata_to_binary(body) == Base.decode16!(row["open_hex"], case: :lower),
    do: raise("Native chest open body differs")

  {_, body} = Valimc.Menus.Packets.chest_inventory(17, rows, storage, %Inventory{slots: slots})

  unless IO.iodata_to_binary(body) == Base.decode16!(row["content_hex"], case: :lower),
    do: raise("Native chest content body differs")

  {:ok, click} =
    Valimc.Protocol.InventoryClick.decode(
      Base.decode16!(row["pickup_hex"], case: :lower),
      rows * 9 + 36
    )

  true = click.container == 17 and click.slot == rows * 9 + 27 and click.action == :pickup
  true = click.predicted_slots == %{click.slot => nil}
  true = click.predicted_cursor.item_id == Valimc.Protocol.ItemTypes.id("oak_planks")
  true = click.predicted_cursor.count == 1

  unless row["opens"] == 1 and row["closes"] == 1 and row["after_close"] == row["storage"],
    do: raise("Native chest close/lifecycle differs")
end

for row <- facts["offhand_corrections"] do
  true = row["slot"] == 40
  {_, body} = Packets.player_inventory_slot(40, stack.(row["stack"]))
  true = IO.iodata_to_binary(body) == Base.decode16!(row["hex"], case: :lower)
end

[barrel] = facts["barrels"]
true = barrel["chest_menu"] and barrel["size"] == 27 and length(barrel["slots"]) == 63
{:ok, type} = Menu.type(Menu.storage(:barrel))
true = type == barrel["type"]

for {[kind, index], wire} <- Enum.with_index(barrel["slots"]) do
  expected = if kind == "container", do: {:container, index}, else: index
  {:ok, ^expected} = Menu.address(Menu.storage(:barrel), wire)
end

{_, body} = Valimc.Menus.Packets.open_storage(17, :barrel)
true = IO.iodata_to_binary(body) == Base.decode16!(barrel["open_hex"], case: :lower)

IO.puts(
  "PASS: the native barrel menu (a three-row chest menu, 63 slot identities) and its titled open body"
)

shulkers = facts["shulker_boxes"]
true = length(shulkers) == 2
shulker_menu = Menu.storage(:shulker_box)

for box <- shulkers do
  true = box["shulker_menu"] and box["size"] == 27 and length(box["slots"]) == 63
  {:ok, type} = Menu.type(shulker_menu)
  true = type == box["type"]
  probes = Enum.map(box["probes"], &Valimc.Protocol.ItemStack.new/1)

  for {{[kind, index], accepts}, wire} <-
        Enum.with_index(Enum.zip(box["slots"], box["accepts"])) do
    expected = if kind == "container", do: {:container, index}, else: index
    {:ok, ^expected} = Menu.address(shulker_menu, wire)

    true =
      Enum.map(probes, &Menu.may_place?(shulker_menu, expected, &1)) == accepts
  end

  {_, body} = Valimc.Menus.Packets.open_storage(17, :shulker_box)
  true = IO.iodata_to_binary(body) == Base.decode16!(box["open_hex"], case: :lower)
end

IO.puts(
  "PASS: the native shulker box menu (#{length(shulkers)} boxes, 63 slot identities, the slots' refusal of shulker boxes) and its titled open body"
)

# Ender chests (VMC-032c3): a three-row chest menu over the player's 27 ender slots.
[ender] = facts["ender_chests"]
true = ender["chest_menu"] and ender["size"] == 27 and length(ender["slots"]) == 63
{:ok, type} = Menu.type(Menu.storage(:ender_chest))
true = type == ender["type"]

for {[kind, index], wire} <- Enum.with_index(ender["slots"]) do
  expected = if kind == "container", do: {:container, index}, else: index
  {:ok, ^expected} = Menu.address(Menu.storage(:ender_chest), wire)
end

{_, body} = Valimc.Menus.Packets.open_storage(17, :ender_chest)
true = IO.iodata_to_binary(body) == Base.decode16!(ender["open_hex"], case: :lower)

IO.puts(
  "PASS: the native ender chest menu (a three-row chest menu over the player's 27 slots, 63 slot identities) and its titled open body"
)

# Named containers (VMC-032c5): the name is the title in place of the default.
named = facts["named"]
true = length(named) == 9

for row <- named do
  name = {:string, row["name"]}

  {_, body} =
    case row["block"] do
      "chest" ->
        Valimc.Menus.Packets.open_chest(17, 3, name)

      "barrel" ->
        Valimc.Menus.Packets.open_storage(17, :barrel, name)

      "shulker_box" ->
        Valimc.Menus.Packets.open_storage(17, :shulker_box, name)

      kind when kind in ~w(furnace smoker blast_furnace) ->
        Valimc.Menus.Packets.open_cooking(17, String.to_existing_atom(kind), name)

      kind ->
        Valimc.Menus.Packets.open_machine(17, String.to_existing_atom(kind), name)
    end

  unless IO.iodata_to_binary(body) == Base.decode16!(row["open_hex"], case: :lower),
    do: raise("Native named #{row["block"]} open body differs")
end

IO.puts(
  "PASS: #{length(named)} named containers' open bodies titled by their names (chest, barrel, shulker box, the furnace family, hopper, dropper, dispenser)"
)

IO.puts(
  "PASS: six native chest layouts/405 slot identities, open/content bodies/hotbar pickup input and storage-preserving empty-cursor close. Live authorization/exchanges require separate checks."
)
