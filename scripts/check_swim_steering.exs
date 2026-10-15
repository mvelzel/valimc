alias Valimc.Physics.SwimSteering
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end

for c <- cases do
  {:ok, look} = SwimSteering.look_y(c["pitch"])

  if bits.(look) != bits.(c["look_y"]),
    do: raise("Native swim look mismatch #{inspect(c)} #{look}")

  {:ok, actual} =
    SwimSteering.step(
      List.to_tuple(c["initial"]),
      look,
      c["swimming"],
      c["jump"],
      c["above_fluid"],
      c["passenger"]
    )

  if Enum.map(Tuple.to_list(actual), bits) != Enum.map(c["velocity"], bits),
    do: raise("Native swim steering mismatch #{inspect(c)} #{inspect(actual)}")
end

IO.puts("PASS: #{length(cases)} native swim steering and camera look vectors.")
