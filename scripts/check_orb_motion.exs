alias Valimc.Physics.OrbMotion
[path] = System.argv()
data = path |> File.read!() |> JSON.decode!()
true = data["version"] == "26.3"
true = data["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"
true = length(data["launches"]) == 56 and length(data["ticks"]) == 5184
true = length(data["ages"]) == 5

bits = fn vector ->
  for n <- Tuple.to_list(vector),
      do: Base.encode16(<<n::float-64>>, case: :lower)
end

tuple = &List.to_tuple/1

Enum.each(data["launches"], fn row ->
  {:ok, result} =
    OrbMotion.launch(tuple.(row["position"]), tuple.(row["direction"]), tuple.(row["draws"]))

  unless bits.(result.position) == row["position_bits"] and
           bits.(result.velocity) == row["velocity_bits"],
         do: raise("Native launch differs: #{inspect({row, result})}")
end)

IO.puts("PASS: 56 bit-exact native XP launches (orb tick motion is not live).")
