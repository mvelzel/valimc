alias Valimc.Physics.{Box, SneakEdges}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

for c <- cases do
  supports = Enum.map(c["supports"], &List.to_tuple/1)
  Process.put(:edge_queries, [])

  free? = fn box ->
    Process.put(:edge_queries, [box | Process.get(:edge_queries)])
    {:ok, not Enum.any?(supports, &Box.intersects?(box, &1))}
  end

  facts = %SneakEdges{
    flying: c["flying"],
    shift: c["shift"],
    on_ground: c["ground"],
    fall_distance: c["fall"],
    max_step: c["step"],
    mover: String.to_existing_atom(c["mover"])
  }

  {:ok, actual} =
    SneakEdges.step(List.to_tuple(c["box"]), List.to_tuple(c["requested"]), facts, free?)

  queries = Process.delete(:edge_queries) |> Enum.reverse()

  unless actual.requested == List.to_tuple(c["result"]) and actual.queries == length(queries) and
           queries == Enum.map(c["queries"], &List.to_tuple/1),
         do: raise("Native edge mismatch: #{inspect({c, actual, queries}, limit: :infinity)}")
end

IO.puts("PASS: #{length(cases)} native player edge displacements/query traces.")
