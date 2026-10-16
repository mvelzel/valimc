alias Valimc.Physics.MotionBlocks
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
unless length(cases) == MotionBlocks.state_count(), do: raise("State coverage differs")

Enum.each(Enum.with_index(cases), fn {c, index} ->
  unless c["id"] == index, do: raise("Non-contiguous native state coverage")
  {:ok, actual} = MotionBlocks.fetch(index)
  encoded = Map.new(actual, fn {k, v} -> {Atom.to_string(k), v} end)
  if encoded != c["properties"], do: raise("Motion block facts differ for #{index}")

  unless MotionBlocks.fence?(index) == c["fence"] and
           MotionBlocks.uses_own_speed?(index) == c["speed_override"],
         do: raise("Contextual material state differs for #{index}")
end)

IO.puts("PASS: #{length(cases)} native block motion facts match compiled lookups.")
