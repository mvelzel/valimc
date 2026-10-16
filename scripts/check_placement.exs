alias Valimc.Physics.Placement
alias Valimc.Protocol.UseItemOn
[facts_path, cases_path] = System.argv()
facts = facts_path |> File.read!() |> JSON.decode!()

unless facts == JSON.decode!(File.read!("priv/physics/placement.json")),
  do: raise("Placement facts differ")

cases = cases_path |> File.read!() |> JSON.decode!()

for [item, clicked, adjacent, face, y, position, replace, allowed, target, state] <-
      cases["contexts"] do
  request = %{position: List.to_tuple(position), face: face, cursor: {0.5, y, 0.5}}
  result = Placement.candidate(item, clicked, adjacent, request)

  expected =
    if allowed,
      do: {:ok, %{position: List.to_tuple(target), state: state, replace_clicked: replace}},
      else: {:error, :occupied}

  unless result == expected,
    do:
      raise(
        "Native placement differs #{inspect({item, clicked, adjacent, request, result, expected})}"
      )
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

  if Valimc.PlayerInteraction.valid_hit?(decoded.position, decoded.cursor),
    do: raise("Nonfinite hit gained authority")
end

unless length(cases["contexts"]) == 518_964 and length(cases["packets"]) == 576 and
         length(cases["nonfinite"]) == 9,
       do: raise("Missing placement contexts/codecs")

IO.puts(
  "PASS: 518,964 native placement candidates, 576 block-use packets and nine nonfinite negatives; final admission remains separate."
)
