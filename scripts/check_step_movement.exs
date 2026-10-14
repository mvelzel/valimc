alias Valimc.Physics.{Box, Shape, StepMovement}
[file] = System.argv()
facts = file |> File.read!() |> JSON.decode!()
shapes = facts["shapes"] |> Enum.map(&Shape.from_facts!/1) |> List.to_tuple()
shape_list = fn ids, offset -> Enum.map(ids, &Shape.move(elem(shapes, &1), offset)) end
bits = fn {x, y, z} -> Enum.map([x, y, z], &Base.encode16(<<&1::float-64>>, case: :lower)) end

for {c, index} <- Enum.with_index(facts["cases"]) do
  box = c["box"] |> List.to_tuple() |> Box.new()
  offset = List.to_tuple(c["offset"])
  initial = shape_list.(c["initial"], offset)
  steps = shape_list.(c["steps"], offset)

  if c["queries"] != [] and
       Box.expand_towards(box, List.to_tuple(c["request"])) != List.to_tuple(hd(c["queries"])),
     do: raise("Native initial query differs at #{index}")

  prepared =
    StepMovement.prepare(box, initial, List.to_tuple(c["request"]), c["max_step"], c["grounded"])

  result =
    case prepared do
      {:resolved, v} ->
        if length(c["queries"]) > 1, do: raise("Missed native step phase at #{index}")
        v

      {:step, plan} ->
        if length(c["queries"]) != 2 or plan.query != List.to_tuple(Enum.at(c["queries"], 1)),
          do:
            raise("Native step query differs at #{index}: #{inspect(c)} actual #{inspect(plan)}")

        {:ok, v} = StepMovement.finish(plan, steps)
        v

      error ->
        raise "Unexpected step preparation at #{index}: #{inspect(error)}"
    end

  if bits.(result) != c["result_bits"],
    do: raise("Native step differs at #{index}: #{inspect(c)} actual #{inspect(result)}")
end

for c <- facts["heights"] do
  box = c["box"] |> List.to_tuple() |> Box.new()
  supplied = Enum.map(c["shapes"], &elem(shapes, &1))
  {:ok, heights} = StepMovement.candidate_heights(box, supplied, c["max_step"], c["previous"])
  actual = Enum.map(heights, &Base.encode16(<<&1::float-32>>, case: :lower))

  if actual != c["height_bits"],
    do: raise("Native candidate set differs: #{inspect(c)} actual #{inspect(actual)}")
end

IO.puts(
  "PASS: #{length(facts["cases"])} native step movements and #{length(facts["heights"])} float32 candidate sets."
)
