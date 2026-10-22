alias Valimc.Native
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()
vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

for c <- cases do
  inputs = Enum.map(c["inputs"], &{vec.(&1["from"]), vec.(&1["actual"]), vec.(&1["axis"])})

  {:ok, {actual, count}} =
    Native.physics_player_parity(:paths, {inputs, vec.(c["old"]), vec.(c["current"])})

  expected =
    Enum.map(c["paths"], fn p ->
      {List.to_tuple(p["from"]), List.to_tuple(p["to"]),
       if(p["axis"] == nil, do: nil, else: List.to_tuple(p["axis"]))}
    end)

  if actual != expected or count > 100,
    do: raise("History mismatch: #{inspect({c, actual}, limit: :infinity)}")
end

IO.puts("PASS: #{length(cases)} native bounded movement history/gap cases.")
