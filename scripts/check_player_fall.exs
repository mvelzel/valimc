alias Valimc.Player.Motion

[path] = System.argv()
cases = path |> File.read!() |> :json.decode()

Enum.each(cases, fn c ->
  result = Motion.fall_step(c["initial"], c["dy"], c["ground"], c["water"])
  expected = {c["distance"], c["landed"]}
  if result != expected, do: raise("Native fall mismatch #{inspect(c)}: #{inspect(result)}")
end)

IO.puts("PASS: #{length(cases)} native fall accumulation, rounding, landing and water cases.")
