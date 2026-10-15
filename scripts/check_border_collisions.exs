alias Valimc.Physics.BorderSnapshot
[path] = System.argv()
native = path |> File.read!() |> JSON.decode!()

decode = fn values ->
  values
  |> Enum.map(fn bits ->
    <<value::float-64>> = Base.decode16!(bits, case: :lower)
    value
  end)
  |> List.to_tuple()
end

bits = fn values ->
  for value <- Tuple.to_list(values), do: Base.encode16(<<value::float-64>>, case: :lower)
end

for {c, index} <- Enum.with_index(native["cases"]) do
  {x, z} = decode.(c["center"])
  {:ok, border} = BorderSnapshot.new(x, z, c["diameter"], c["absolute_max"])
  point = decode.(c["point"])
  box = decode.(c["box"])
  {:ok, bounds} = BorderSnapshot.bounds(border)
  {:ok, contains_point} = BorderSnapshot.contains?(border, point)
  {:ok, contains_box} = BorderSnapshot.contains?(border, box)
  {:ok, distance} = BorderSnapshot.distance(border, point)
  {:ok, clear} = BorderSnapshot.no_collision?(border, point, box)
  {:ok, anonymous_clear} = BorderSnapshot.no_collision?(border, nil, box)

  if bits.(bounds) != c["bounds"] or bits.({distance}) != c["distance"] or
       contains_point != c["contains_point"] or contains_box != c["contains_box"] or
       clear != c["clear"] or anonymous_clear != c["anonymous_clear"],
     do:
       raise(
         "Native border mismatch at #{index}: #{inspect(c)} / #{inspect({bounds, distance, contains_point, contains_box, clear})}"
       )
end

IO.puts(
  "PASS: #{length(native["cases"])} native border bounds, containment, distance and collision cases."
)
