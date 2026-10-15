alias Valimc.Physics.Swimming
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()

for c <- cases do
  actual =
    Swimming.next(
      c["previous"],
      c["sprint"],
      c["water"],
      c["underwater"],
      c["feet_water"],
      c["passenger"]
    )

  if actual != c["swimming"], do: raise("Native swimming mismatch #{inspect(c)}")
end

IO.puts("PASS: #{length(cases)} native swimming transitions.")
