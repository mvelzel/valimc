alias Valimc.Physics.{EntityCollisions, Shape}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

box = fn values ->
  values
  |> Enum.map(fn bits ->
    <<value::float-64>> = Base.decode16!(bits, case: :lower)
    value
  end)
  |> List.to_tuple()
end

bits = fn tuple ->
  for value <- Tuple.to_list(tuple), do: Base.encode16(<<value::float-64>>, case: :lower)
end

for {c, index} <- Enum.with_index(cases) do
  candidates =
    Enum.map(c["candidates"], fn e ->
      %{
        id: e["id"],
        box: box.(e["box"]),
        spectator: e["spectator"],
        collidable: e["collidable"],
        same_vehicle: e["same_vehicle"]
      }
    end)

  expected =
    Enum.map(c["colliders"], fn e ->
      %{id: e["id"], box: box.(e["box"]), shape: Shape.from_world_facts!(e["geometry"])}
    end)

  {:ok, actual} = EntityCollisions.collect(box.(c["box"]), c["subject"], candidates)
  query = if actual.query_box, do: bits.(actual.query_box)

  if query != c["query_box"] or actual.colliders != expected,
    do:
      raise(
        "Native entity collection mismatch at #{index}: #{inspect(c)} actual #{inspect(actual)}"
      )
end

IO.puts("PASS: #{length(cases)} native entity predicates, margins, thresholds, order and shapes.")
