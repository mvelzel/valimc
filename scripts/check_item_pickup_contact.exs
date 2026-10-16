alias Valimc.Physics.ItemPickup
[path] = System.argv()
rows = :json.decode(File.read!(path))

for {row, n} <- Enum.with_index(rows) do
  body = List.to_tuple(row["body"])
  position = List.to_tuple(row["position"])

  unless ItemPickup.query_box(body) == {:ok, List.to_tuple(row["query"])} and
           ItemPickup.contact?(body, position) == row["contact"],
         do: raise("pickup contact #{n}: #{inspect(row)}")
end

IO.puts("PASS: #{length(rows)} native pickup query/contact boundaries.")
