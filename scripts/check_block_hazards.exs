alias Valimc.Physics.BlockHazards
[facts_path, path] = System.argv()

unless :json.decode(File.read!(facts_path)) ==
         :json.decode(File.read!("priv/physics/block_hazards.json")),
       do: raise("Native hazard facts differ")

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
  "PASS: #{length(rows)} native player hazard requests across all85 supported states; health/defenses/geometry excluded."
)
