alias Valimc.Physics.Mining
[cases_path, ticks_path] = System.argv()
count = Valimc.Registry.BlockFacts.count()

bits = fn
  :nan -> <<0x7FC00000::32>>
  :infinity -> <<0x7F800000::32>>
  :negative_infinity -> <<0xFF800000::32>>
  value -> <<value::float-32>>
end

rows = cases_path |> File.read!() |> JSON.decode!()

for row <- rows do
  expected = Base.decode16!(row["progress_bits"], case: :lower)

  actual =
    for id <- 0..(count - 1), into: <<>> do
      {:ok, rate} = Mining.rate(id, row["speed"], row["correct"])
      bits.(rate)
    end

  unless actual == expected,
    do: raise("Native mining rate differs #{inspect(Map.drop(row, ["progress_bits"]))}")
end

ticks = ticks_path |> File.read!() |> JSON.decode!()

for row <- ticks do
  {:ok, rate} = Mining.rate(row["state"], row["speed"], row["correct"])
  {:ok, result} = Mining.advance(rate, row["elapsed"])
  actual = result.progress |> bits.() |> Base.encode16(case: :lower)

  unless actual == row["progress_bits"] and result.crack == row["crack"] and
           row["calls"] == if(result.crack == -2_147_483_648, do: 0, else: 1),
         do: raise("Native mining tick/crack differs #{inspect({row, result})}")
end

IO.puts(
  "PASS: #{count * length(rows)} bit-exact native mining rates and #{length(ticks)} actual elapsed/crack callback prefixes."
)
