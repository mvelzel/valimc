alias Valimc.Native
alias Valimc.Physics.Kernel
[file] = System.argv()
facts = file |> File.read!() |> JSON.decode!()
shapes = facts["shapes"] |> Enum.map(&Kernel.shape/1) |> List.to_tuple()
floats = fn values -> values |> Enum.map(&(&1 * 1.0)) |> List.to_tuple() end
placed = fn ids, offset -> Enum.map(ids, &{elem(shapes, &1), nil, offset}) end
bits = fn {x, y, z} -> Enum.map([x, y, z], &Base.encode16(<<&1::float-64>>, case: :lower)) end

expand = fn {x0, y0, z0, x1, y1, z1}, {dx, dy, dz} ->
  {x0 + min(dx, 0), y0 + min(dy, 0), z0 + min(dz, 0), x1 + max(dx, 0), y1 + max(dy, 0),
   z1 + max(dz, 0)}
end

for {c, index} <- Enum.with_index(facts["cases"]) do
  box = floats.(c["box"])
  offset = floats.(c["offset"])
  request = floats.(c["request"])

  if c["queries"] != [] and expand.(box, request) != floats.(hd(c["queries"])),
    do: raise("Native initial query differs at #{index}")

  {result, step_query} =
    Native.physics_parity_step(
      placed.(c["initial"], offset),
      placed.(c["steps"], offset),
      box,
      request,
      c["max_step"] * 1.0,
      c["grounded"]
    )

  case step_query do
    nil ->
      if length(c["queries"]) > 1, do: raise("Missed native step phase at #{index}")

    query ->
      if length(c["queries"]) != 2 or query != floats.(Enum.at(c["queries"], 1)),
        do: raise("Native step query differs at #{index}: #{inspect(c)} actual #{inspect(query)}")
  end

  if bits.(result) != c["result_bits"],
    do: raise("Native step differs at #{index}: #{inspect(c)} actual #{inspect(result)}")
end

for c <- facts["heights"] do
  supplied = Enum.map(c["shapes"], &{elem(shapes, &1), nil, nil})

  heights =
    Native.physics_parity_heights(
      supplied,
      floats.(c["box"]),
      c["max_step"] * 1.0,
      c["previous"] * 1.0
    )

  actual = Enum.map(heights, &Base.encode16(<<&1::float-32>>, case: :lower))

  if actual != c["height_bits"],
    do: raise("Native candidate set differs: #{inspect(c)} actual #{inspect(actual)}")
end

IO.puts(
  "PASS: #{length(facts["cases"])} native step movements and #{length(facts["heights"])} float32 candidate sets through the kernel."
)
