alias Valimc.Native
[path] = System.argv()
data = path |> File.read!() |> :json.decode()
cases = data["cases"]

keys =
  ~w(on_ground friction friction_modifier air_drag_modifier gravity levitation discard_friction omnidirectional)a

gravity = fn base, vy, slow ->
  {:ok, g} = Native.physics_player_parity(:gravity, {base * 1.0, vy * 1.0, slow})
  g
end

float = fn
  v when is_number(v) -> v * 1.0
  v -> v
end

bits = fn v -> for n <- Tuple.to_list(v), do: <<n::float-64>> end

Enum.each(cases, fn c ->
  facts =
    Map.new(keys, fn key ->
      name = if key == :on_ground, do: "ground", else: Atom.to_string(key)
      {key, float.(Map.fetch!(c, name))}
    end)
    |> Map.update!(:levitation, fn value -> if value < 0, do: nil, else: trunc(value) end)

  facts =
    Map.put(facts, :gravity, gravity.(c["gravity"], Enum.at(c["movement"], 1), c["slow_falling"]))

  {:ok, result} =
    Native.physics_player_parity(
      :air_step,
      {List.to_tuple(Enum.map(c["movement"], float)), facts}
    )

  actual = bits.(result)
  expected = bits.(List.to_tuple(c["velocity"]))
  if actual != expected, do: raise("Native air motion mismatch #{inspect(c)}: #{inspect(result)}")
end)

Enum.each(data["traces"], fn trace ->
  initial = trace["initial"] |> Enum.map(float) |> List.to_tuple()

  Enum.reduce(trace["steps"], initial, fn step, previous ->
    facts = %{
      on_ground: step["ground"],
      friction: trace["friction"] * 1.0,
      friction_modifier: 1.0,
      air_drag_modifier: 1.0,
      gravity: gravity.(step["gravity"], elem(previous, 1), step["slow_falling"]),
      levitation: if(step["levitation"] < 0, do: nil, else: step["levitation"]),
      discard_friction: false,
      omnidirectional: false
    }

    {:ok, result} = Native.physics_player_parity(:air_step, {previous, facts})

    if bits.(result) != bits.(List.to_tuple(step["velocity"])),
      do: raise("Native accumulated air trace mismatch: #{inspect(step)}")

    result
  end)
end)

IO.puts(
  "PASS: #{length(cases)} bit-exact native air updates and #{length(data["traces"])} 200-step traces."
)
