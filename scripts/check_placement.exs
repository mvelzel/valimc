# VMC-029d: PlacementOracle's coverage matrix on ValiMC's placement. Per
# case (a block item clicked on a block from a real yaw and pitch, with a
# cursor, sneaking, the target's light and redstone power and random cells
# around, relative to the clicked block) `Valimc.Blocks.Placement` picks the target and the
# click's inputs and the placement rules (`Rules::place`, through
# `Native.rules_placement_cases`) say what is written; it must be what
# vanilla's `BlockItem.useOn` wrote, or a refusal where vanilla refused.
# Draws answer 0 on both sides. The use-on packet codec cases follow.
alias Valimc.Blocks.Placement
alias Valimc.Protocol.UseItemOn
[facts_path, cases_path] = System.argv()

unless JSON.decode!(File.read!(facts_path)) ==
         JSON.decode!(File.read!("priv/physics/placement.json")),
       do: raise("Placement facts differ")

cases = cases_path |> File.read!() |> JSON.decode!()
rules = Valimc.World.BlockRules.native()

prepared =
  for [
        item,
        yaw,
        pitch,
        face,
        [cx, cy, cz],
        secondary,
        inside,
        light,
        sky,
        signals,
        cells,
        expected
      ] <-
        cases["matrix"] do
    cells = Map.new(cells, fn [x, y, z, state] -> {{x, y, z}, state} end)
    signals = Map.new(signals, fn [x, y, z, on] -> {{x, y, z}, on} end)

    request = %{
      position: {0, 0, 0},
      face: face,
      cursor: {cx, cy, cz},
      yaw: yaw,
      pitch: pitch,
      secondary: secondary,
      inside: inside
    }

    {:ok, %{position: target, values: values}} =
      Placement.target(item, Map.get(cells, {0, 0, 0}, 0), request)

    {tx, ty, tz} = target
    signal = &if(Map.get(signals, &1, false), do: 1, else: 0)

    values =
      values
      |> List.replace_at(8, light)
      |> List.replace_at(9, if(sky, do: 1, else: 0))
      |> List.replace_at(10, signal.(target))
      |> List.replace_at(11, signal.({tx, ty + 1, tz}))

    cells = for {{x, y, z}, state} <- cells, do: {x, y, z, state}
    expected = expected && Enum.sort(for [x, y, z, state] <- expected, do: {x, y, z, state})
    {{item, values, target, cells}, expected}
  end

{:ok, results} =
  Valimc.Native.rules_placement_cases(rules, Enum.map(prepared, &elem(&1, 0)))

failures =
  for {{{item, values, target, _cells}, expected}, ours} <- Enum.zip(prepared, results),
      (ours && Enum.sort(ours)) != expected,
      do: {Valimc.Protocol.ItemTypes.item(item)["name"], values, target, expected, ours}

items = prepared |> Enum.map(&elem(elem(&1, 0), 0)) |> Enum.uniq() |> length()

if failures != [] do
  failures
  |> Enum.group_by(&elem(&1, 0))
  |> Enum.sort_by(fn {_, rows} -> -length(rows) end)
  |> Enum.take(40)
  |> Enum.each(fn {name, [first | _] = rows} ->
    IO.puts("#{name}: #{length(rows)} cases differ, e.g. #{inspect(first, limit: :infinity)}")
  end)

  raise "#{length(failures)} of #{length(prepared)} placement cases differ"
end

for row <- cases["packets"] do
  expected = %{
    hand: String.to_existing_atom(row["hand"]),
    position: List.to_tuple(row["position"]),
    cursor: List.to_tuple(row["cursor"]),
    face: row["face"],
    sequence: row["sequence"],
    inside: row["inside"],
    border: row["border"]
  }

  unless UseItemOn.decode(Base.decode16!(row["wire"], case: :lower)) == {:ok, expected},
    do: raise("Native use-on codec differs #{inspect(row)}")

  unless UseItemOn.encode(expected) == {:ok, Base.decode16!(row["wire"], case: :lower)},
    do: raise("Native use-on re-encoding differs #{inspect(row)}")
end

for row <- cases["nonfinite"] do
  {:ok, %{cursor: :nonfinite, sequence: 1} = decoded} =
    UseItemOn.decode(Base.decode16!(row["wire"], case: :lower))

  if Valimc.Living.Interaction.valid_hit?(decoded.position, decoded.cursor),
    do: raise("Nonfinite hit gained authority")
end

unless length(cases["packets"]) == 576 and length(cases["nonfinite"]) == 9,
  do: raise("Missing use-on codec cases")

IO.puts(
  "PASS: #{length(prepared)} placement cases of #{items} block items as vanilla places them, " <>
    "576 block-use packets and nine nonfinite negatives."
)
