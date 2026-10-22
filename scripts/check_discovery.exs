[path] = System.argv()
rows = File.read!(path) |> String.split("\n", trim: true) |> Enum.map(&:json.decode/1)

for row <- rows do
  case row["type"] do
    "route" ->
      expected = if row["route"] == :null, do: nil, else: row["route"]
      {:ok, actual} = Valimc.Net.Auth.DiscoveryDocument.decode(row["body"])
      true = actual == expected

    "retry" ->
      true =
        Valimc.Net.Auth.DiscoveryDocument.retry_delay(row["loaded"], row["failures"]) ==
          row["delay"]

    "invalid" ->
      {:error, :invalid_discovery} = Valimc.Net.Auth.DiscoveryDocument.decode(row["body"])
  end
end

IO.puts("PASS: #{length(rows)} pinned discovery route and refresh/backoff facts.")
