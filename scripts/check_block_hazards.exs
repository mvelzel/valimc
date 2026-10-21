alias Valimc.Physics.BlockHazards
[path] = System.argv()

rows = :json.decode(File.read!(path))

for row <- rows do
  {:ok, request} =
    BlockHazards.request(
      row["state"],
      row["careful"],
      row["client"],
      List.to_tuple(row["known"]),
      List.to_tuple(row["previous"])
    )

  damage =
    case request do
      nil -> []
      {source, amount} -> ["#{source}:#{amount}"]
    end

  unless damage == row["damage"], do: raise("Native hazard differs: #{inspect({row, request})}")
end

IO.puts(
  "PASS: #{length(rows)} native player hazard requests across all 85 supported states; health/defenses/geometry excluded."
)
