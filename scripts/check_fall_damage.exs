alias Valimc.Physics.FallDamage
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  {:ok, actual} =
    FallDamage.calculate(c["distance"], c["material"], %FallDamage{
      safe_distance: c["safe"],
      attribute_multiplier: c["multiplier"],
      immune: c["immune"]
    })

  unless actual == c["damage"], do: raise("Native fall damage mismatch #{inspect({c, actual})}")
end

IO.puts("PASS: #{length(cases)} native fall damage calculations.")
