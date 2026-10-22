alias Valimc.{MenuAccess, PlayerInteraction}
alias Valimc.Protocol.Data
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()

unless facts["version"] == "26.3" and
         facts["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c" and
         facts["table_item"] == Data.item("crafting_table") and
         facts["table_state"] == Data.item_block(Data.item("crafting_table")) and
         length(facts["uses"]) == 128 and length(facts["validity"]) == 112,
       do: raise("Incomplete native table access facts")

for [mode, secondary, main, off, hand, table, opens, consumes] <- facts["uses"] do
  mode = String.to_existing_atom(mode)
  hand = if hand == "MAIN_HAND", do: :main, else: :off
  actual = table and PlayerInteraction.opens_block_menu?(mode, hand, secondary, main, off)

  unless actual == (opens == 1) and actual == consumes,
    do:
      raise(
        "Native table-use dispatch differs #{inspect({mode, secondary, main, off, hand, table})}"
      )
end

for [mode, table, position, eye, expected] <- facts["validity"] do
  block = if table, do: facts["table_state"], else: Data.block("stone")

  actual =
    MenuAccess.valid_view?(
      :table,
      block,
      String.to_existing_atom(mode),
      List.to_tuple(eye),
      List.to_tuple(position)
    )

  unless actual == expected,
    do: raise("Native menu validity differs #{inspect({mode, table, position, eye})}")
end

IO.puts("PASS:128 actual native table-use decisions and112 actual menu validity boundaries.")
