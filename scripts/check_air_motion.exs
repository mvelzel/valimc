alias Valimc.Living.Attributes
alias Valimc.Physics.AirMotion
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
cases = data["cases"]
keys = Map.keys(%AirMotion{}) -- [:__struct__]
bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

Enum.each(cases, fn c ->
  facts =
    Map.new(keys, fn key ->
      name = if key == :on_ground, do: "ground", else: Atom.to_string(key)
      {key, Map.fetch!(c, name)}
    end)
    |> Map.update!(:levitation, fn value -> if value < 0, do: nil, else: value end)

  {:ok, gravity} =
    Attributes.gravity(c["gravity"], Enum.at(c["movement"], 1), c["slow_falling"])

  facts = Map.put(facts, :gravity, gravity)

  {:ok, result} = AirMotion.step(List.to_tuple(c["movement"]), struct!(AirMotion, facts))
  actual = bits.(result)
  expected = bits.(List.to_tuple(c["velocity"]))
  if actual != expected, do: raise("Native air motion mismatch #{inspect(c)}: #{inspect(result)}")
end)

Enum.each(data["traces"], fn trace ->
  Enum.reduce(trace["steps"], List.to_tuple(trace["initial"]), fn step, previous ->
    {:ok, gravity} =
      Attributes.gravity(step["gravity"], elem(previous, 1), step["slow_falling"])

    facts = %AirMotion{
      on_ground: step["ground"],
      friction: trace["friction"],
      gravity: gravity,
      levitation: if(step["levitation"] < 0, do: nil, else: step["levitation"])
    }

    {:ok, result} = AirMotion.step(previous, facts)

    if bits.(result) != bits.(List.to_tuple(step["velocity"])),
      do: raise("Native accumulated air trace mismatch: #{inspect(step)}")

    result
  end)
end)

IO.puts(
  "PASS: #{length(cases)} bit-exact native air updates and #{length(data["traces"])} 200-step traces."
)
