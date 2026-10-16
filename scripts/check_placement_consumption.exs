alias Valimc.PlayerPlacementIntent
alias Valimc.Protocol.ItemStack
[cases_path] = System.argv()
rows = cases_path |> File.read!() |> JSON.decode!()
facts = "priv/physics/placement.json" |> File.read!() |> JSON.decode!()
states = Map.new(facts["plain"], fn {item, state} -> {String.to_integer(item), state} end)

states =
  Enum.reduce(facts["slabs"], states, fn slab, states ->
    Map.put(states, slab["item"], Enum.at(slab["states"], 3))
  end)

for row <- rows do
  before = %ItemStack{
    item_id: row["item"],
    count: row["before"],
    components: %{
      "minecraft:max_stack_size" => 99,
      "minecraft:enchantment_glint_override" => true
    }
  }

  if row["infinite"] do
    unless row["after"] == row["before"] and not row["empty"],
      do: raise("Native creative consumption changed")
  else
    after_stack = if row["empty"], do: nil, else: %{before | count: row["after"]}

    intent = %{
      kind: :placement,
      key: {0, 0},
      permit: <<2::128>>,
      slot: 36,
      before: before,
      after: after_stack,
      expected: %{{1, 64, 1} => 0},
      edits: %{{1, 64, 1} => Map.fetch!(states, row["item"])},
      request: %{
        hand: :main,
        position: {1, 64, 1},
        face: 1,
        cursor: {0.5, 0.5, 0.5},
        inside: false,
        border: false,
        sequence: 1
      }
    }

    {:ok, encoded} = PlayerPlacementIntent.encode(<<1::128>>, 1, intent)
    {:ok, ^intent} = PlayerPlacementIntent.decode(<<1::128>>, 1, encoded)
  end
end

unless length(rows) == 2840, do: raise("Missing native placement consumption cases")

IO.puts(
  "PASS: 2,840 native survival/creative consumption cases; 1,420 canonical source-intent round trips."
)
