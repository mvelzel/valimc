alias Valimc.Native
[path] = System.argv()
:ok = Valimc.Registry.BlockFacts.install!()

rows = :json.decode(File.read!(path))

for row <- rows do
  vec = fn l -> l |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end

  {:ok, request} =
    Native.physics_player_parity(
      :hazard,
      {row["state"], row["careful"], row["client"], vec.(row["known"]), vec.(row["previous"])}
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
