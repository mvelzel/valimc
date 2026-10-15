alias Valimc.Physics.MovementPaths
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  history =
    Enum.reduce(c["inputs"], %MovementPaths{}, fn input, history ->
      MovementPaths.record(
        history,
        List.to_tuple(input["from"]),
        List.to_tuple(input["actual"]),
        List.to_tuple(input["axis"])
      )
    end)

  actual = MovementPaths.collect(history, List.to_tuple(c["old"]), List.to_tuple(c["current"]))

  expected =
    Enum.map(c["paths"], fn p ->
      %{
        from: List.to_tuple(p["from"]),
        to: List.to_tuple(p["to"]),
        axis: if(p["axis"] == nil, do: nil, else: List.to_tuple(p["axis"]))
      }
    end)

  if actual != expected or history.count > 100,
    do: raise("History mismatch: #{inspect({c, actual}, limit: :infinity)}")
end

IO.puts("PASS: #{length(cases)} native bounded movement history/gap cases.")
