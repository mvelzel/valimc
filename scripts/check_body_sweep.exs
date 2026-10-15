alias Valimc.Physics.{BlockScan, BodySweep, Box, CollisionQuery}
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()

for c <- cases do
  result =
    BodySweep.plan(
      List.to_tuple(c["from"]),
      List.to_tuple(c["to"]),
      List.to_tuple(c["box"]),
      c["stop_after"]
    )

  actual =
    case result do
      {:ok, value} -> value
      error -> raise("Native body sweep failed #{inspect(c)} #{inspect(error)}")
    end

  visits = Enum.map(actual.visits, fn {{x, y, z}, step} -> [x, y, z, step] end)

  unless visits == c["visits"] and actual.complete == c["complete"],
    do: raise("Native body sweep mismatch #{inspect(c)} #{inspect(actual)}")

  delta = Enum.zip_with(c["to"], c["from"], &(&1 - &2)) |> List.to_tuple()
  reverse = delta |> Tuple.to_list() |> Enum.map(&(-&1)) |> List.to_tuple()
  query = c["box"] |> List.to_tuple() |> Box.move(reverse) |> Box.expand_towards(delta)

  case BlockScan.plan(query, CollisionQuery.frame_cell_limit()) do
    {:ok, cells} ->
      acquired = MapSet.new(cells, &elem(&1, 0))

      unless Enum.all?(actual.visits, &MapSet.member?(acquired, elem(&1, 0))),
        do: raise("Body contact outside admitted sweep frame #{inspect(c)}")

    {:error, :block_scan_limit} ->
      :ok
  end
end

IO.puts(
  "PASS: #{length(cases)} native ordered body sweep/early-stop traces and admitted frame coverage."
)
