alias Valimc.Physics.ClimbMotion
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end

check = fn actual, expected ->
  Enum.map(Tuple.to_list(actual), bits) == Enum.map(expected, bits)
end

for c <- cases do
  {:ok, before} =
    ClimbMotion.prepare(List.to_tuple(c["initial"]), c["climbing"], c["shift"], c["scaffolding"])

  unless check.(before.velocity, c["requested"]),
    do: raise("Native climb clamp mismatch #{inspect(c)} #{inspect(before)}")

  if if(before.reset_fall, do: 0.0, else: 5.0) != c["fall_distance"],
    do: raise("Native climb fall mismatch #{inspect(c)}")

  {:ok, actual} =
    ClimbMotion.finish(
      List.to_tuple(c["resolved"]),
      c["climbing"],
      c["horizontal_collision"],
      c["jump"]
    )

  unless check.(actual, c["velocity"]),
    do: raise("Native climb boost mismatch #{inspect(c)} #{inspect(actual)}")
end

IO.puts("PASS: #{length(cases)} native player climb clamps, boost and fall resets.")
