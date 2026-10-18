[path] = System.argv()
raw = JSON.decode!(File.read!(path))

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

true = length(raw["cases"]) == 480

for row <- raw["cases"] do
  [["nextDouble", x], ["nextDouble", y], ["nextDouble", z] | rest] = row["random"]

  piles =
    rest
    |> Enum.chunk_every(7)
    |> Enum.map(fn
      [
        ["nextInt", 21, size],
        ["nextDouble", a],
        ["nextDouble", b],
        ["nextDouble", c],
        ["nextDouble", d],
        ["nextDouble", e],
        ["nextDouble", f]
      ] ->
        {size, {a, b, c, d, e, f}}
    end)

  {:ok, records} =
    Valimc.Physics.ContainerScatter.plan(
      List.to_tuple(row["origin"]),
      row["count"],
      {x, y, z},
      piles
    )

  true = length(records) == length(row["items"])

  for {actual, expected} <- Enum.zip(records, row["items"]) do
    true = actual.count == expected["count"] and actual.pickup_delay == expected["pickup_delay"]

    for {ours, native} <- [
          {actual.position, expected["position"]},
          {actual.velocity, expected["velocity"]}
        ] do
      true = :erlang.term_to_binary(ours) == :erlang.term_to_binary(List.to_tuple(native))
    end
  end

  true = Enum.sum(Enum.map(records, & &1.count)) == row["count"]
end

IO.puts(
  "PASS: 480 native stored-stack split/position/velocity/delay traces, bit-exact coordinates/motion and conserved quantities; component copies/journals/removal remain separate."
)
