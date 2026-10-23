# Original scalar observations from ChestAccessOracle, not upstream sources.
[filename] = System.argv()
raw = JSON.decode!(File.read!(filename))
facts = JSON.decode!(File.read!("priv/protocol/chest_states.json"))
true = facts == raw["facts"]
block = hd(facts["single_states"])

for row <- raw["validity"] do
  actual =
    Valimc.Menus.MenuAccess.valid_view?(
      :chest,
      if(row["present"], do: block),
      String.to_existing_atom(row["mode"]),
      List.to_tuple(row["eye"]),
      List.to_tuple(row["position"])
    )

  unless actual == row["valid"], do: raise("chest validity mismatch: #{inspect(row)}")
end

for row <- facts["states"] do
  true = Valimc.Blocks.Chest.single?(row["state"]) == (row["part"] == "single")
end

IO.puts(
  "PASS: 24 native chest state identities and 112 actual block-entity validity boundaries; opening/physical lifecycle excluded."
)

for row <- raw["combined"] do
  neighbor = List.to_tuple(row["neighbor_position"])
  read = fn at -> if at == neighbor, do: row["neighbor"], else: 0 end
  actual = Valimc.Blocks.Chest.positions(row["state"], {0, 0, 0}, read)
  expected = Enum.map(row["order"], &List.to_tuple/1)
  full = Tuple.duplicate(Valimc.Protocol.ItemStack.new("stone", 64), 27)

  fetch = fn at ->
    %{rows: 3, slots: if(at == {0, 0, 0}, do: full, else: Tuple.duplicate(nil, 27)), revision: 1}
  end

  view =
    case actual do
      [_, _] ->
        {:ok, view} = Valimc.World.Containers.chest_view(actual, fetch)
        view

      [at] ->
        fetch.(at)
    end

  true = Valimc.Blocks.Redstone.entry_signal(view) == row["filled_signal"]

  unless actual == expected,
    do: raise("combined chest order mismatch: #{inspect(row)}: #{inspect(actual)}")
end

IO.puts("PASS: #{length(raw["combined"])} native chest combinations and half slot orders")
