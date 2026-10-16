alias Valimc.{Inventory, TableMenu}
alias Valimc.Protocol.{Data, ItemStack, Packets}
[path, packets_path] = System.argv()

stack = fn
  nil ->
    nil

  [id, count, glint, damage] ->
    components = %{}

    components =
      if glint == nil,
        do: components,
        else: Map.put(components, "minecraft:enchantment_glint_override", glint)

    components =
      if damage == nil, do: components, else: Map.put(components, "minecraft:damage", damage)

    %ItemStack{item_id: id, count: count, components: components}
end

same = fn
  nil, nil ->
    true

  %ItemStack{} = first, %ItemStack{} = second ->
    first.count == second.count and ItemStack.same_item?(first, second)

  _, _ ->
    false
end

same_list = fn first, second ->
  length(first) == length(second) and
    Enum.zip(first, second) |> Enum.all?(fn {first, second} -> same.(first, second) end)
end

actions = [:pickup, :quick_move, :swap, :clone, :throw, :quick_craft, :pickup_all]
cases = path |> File.read!() |> JSON.decode!()

packets =
  Enum.with_index(cases)
  |> Enum.flat_map(fn {[
                         creative,
                         physical,
                         grid,
                         cursor,
                         clicks,
                         visible,
                         after_physical,
                         carried,
                         dropped
                       ], index} ->
    unless length(physical) == 46 and length(grid) == 9 and length(visible) == 46 and
             length(after_physical) == 46,
           do: raise("Incomplete table click trace")

    initial = %Inventory{
      slots:
        physical
        |> Enum.map(stack)
        |> Enum.with_index()
        |> Enum.reject(fn {value, _} -> value == nil end)
        |> Map.new(fn {value, slot} -> {slot, value} end),
      table_inputs: grid |> Enum.map(stack) |> List.to_tuple(),
      carried: stack.(cursor),
      infinite_materials: creative
    }

    {result, drops} =
      Enum.reduce(clicks, {initial, []}, fn [action, slot, button], {inventory, drops} ->
        case TableMenu.plan_click(inventory, Enum.at(actions, action), slot, button) do
          {:ok, next, batch} -> {next, drops ++ batch}
          other -> raise("Table click refused #{inspect({creative, grid, clicks, other})}")
        end
      end)

    expected_owned = Enum.map(after_physical, stack) ++ Enum.map(Enum.slice(visible, 1, 9), stack)

    unless same_list.(TableMenu.contents(result), Enum.map(visible, stack)) and
             same_list.(Inventory.contents(result), expected_owned) and
             same.(result.carried, stack.(carried)) and
             same_list.(drops, Enum.map(dropped, stack)),
           do:
             raise(
               "Native table click differs #{inspect({creative, grid, cursor, clicks, visible, after_physical, carried, dropped, result, drops})}"
             )

    if rem(index, 5) == 0 do
      container = 1 + rem(index, 127)
      {id, bytes} = Packets.table_inventory(container, result)

      unless id == Data.id(:play, :clientbound, "container_set_content"),
        do: raise("Wrong table content packet ID")

      [
        [
          container,
          result.state_id,
          Base.encode16(IO.iodata_to_binary(bytes), case: :lower),
          visible,
          carried
        ]
      ]
    else
      []
    end
  end)

unless length(cases) == 11_990, do: raise("Incomplete table click coverage:#{length(cases)}")
{id, open} = Packets.open_table(17)
unless id == Data.id(:play, :clientbound, "open_screen"), do: raise("Wrong open table packet ID")

File.write!(
  packets_path,
  JSON.encode!(%{open: Base.encode16(IO.iodata_to_binary(open), case: :lower), packets: packets})
)

IO.puts(
  "PASS:11990 actual table click traces across1180 profiles, exact visible/owned results and drops, both permissions and hidden equipment."
)
