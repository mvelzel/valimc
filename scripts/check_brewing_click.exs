# Brewing-stand menu clicks (VMC-034o) against vanilla's `BrewingStandMenu`:
# pickups, shift-clicks and number swaps, and every stock item's shift
# route; the window type is vanilla's.
alias Valimc.Menus.{Click, Inventory, Menu}
alias Valimc.Protocol.ItemStack
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()
{:ok, type} = Menu.type(Menu.brewing())

unless type == facts["menu_type"],
  do: raise("Brewing stand window type #{type}, vanilla #{facts["menu_type"]}")

# Potions stack to 1 by their item, so a stack is its item, count and maximum.
stack = fn
  nil ->
    nil

  [id, count, maximum] ->
    %ItemStack{item_id: id, count: count, components: %{"minecraft:max_stack_size" => maximum}}
end

normal = fn
  nil -> nil
  %ItemStack{} = s -> [s.item_id, s.count, ItemStack.max_stack_size(s)]
end

{accepted, refused} =
  Enum.reduce(facts["cases"] ++ facts["routes"], {0, 0}, fn row, {accepted, refused} ->
    slots =
      for {item, slot} <- Enum.with_index(Enum.map(row["player"], stack)),
          item != nil,
          into: %{},
          do: {slot, item}

    inventory = %Inventory{
      slots: slots,
      carried: stack.(row["cursor"]),
      infinite_materials: row["creative"]
    }

    storage = row["before"] |> Enum.map(stack) |> List.to_tuple()
    action = Map.fetch!(%{0 => :pickup, 1 => :quick_move, 2 => :swap}, row["action"])
    result = Click.plan(Menu.brewing(), storage, inventory, action, row["slot"], row["button"])

    if row["overflow"] do
      unless result == {:error, :unsupported_click},
        do: raise("Overflow was not refused: #{inspect(row)} #{inspect(result)}")

      {accepted, refused + 1}
    else
      {:ok, after_storage, after_inventory, []} = result

      unless Enum.map(Tuple.to_list(after_storage), normal) == row["after"] and
               Enum.map(Inventory.contents(after_inventory), normal) == row["player_after"] and
               normal.(after_inventory.carried) == row["cursor_after"] and row["drops"] == [],
             do: raise("Brewing click differs: #{inspect(row)} ACTUAL #{inspect(result)}")

      {accepted + 1, refused}
    end
  end)

IO.puts(
  "PASS: #{accepted} brewing-stand click plans and shift routes equal vanilla's; #{refused} overflowing swaps refused."
)
