alias Valimc.Physics.Swimming
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()

for c <- cases do
  kernel =
    Swimming.next(
      c["previous"],
      c["sprint"],
      c["water"],
      c["underwater"],
      c["feet_water"],
      c["passenger"]
    )

  actual = kernel and not Map.get(c, "flying", false) and not Map.get(c, "spectator", false)
  if actual != c["swimming"], do: raise("Native swimming mismatch #{inspect(c)}")
end

IO.puts("PASS: #{length(cases)} native swimming transitions.")
