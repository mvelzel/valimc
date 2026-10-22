alias Valimc.Physics.RelativeMotion
[path] = System.argv()
cases = path |> File.read!() |> :json.decode()
bits = fn n -> <<n::float-64>> end

check = fn actual, expected, context ->
  unless Enum.map(Tuple.to_list(actual), bits) == Enum.map(expected, bits),
    do:
      raise(
        "Relative motion mismatch #{inspect(context)} #{inspect(actual)} vs #{inspect(expected)}"
      )
end

for c <- cases["vectors"] do
  input = List.to_tuple(c["input"])
  {:ok, vector} = RelativeMotion.vector(input, c["speed"], c["yaw"])
  check.(vector, c["vector"], c)

  {:ok, velocity} =
    RelativeMotion.accelerate(List.to_tuple(c["initial"]), input, c["speed"], c["yaw"])

  check.(velocity, c["velocity"], c)
end

for c <- cases["intents"] do
  {:ok, intent} =
    Valimc.Player.Input.move_intent(%Valimc.Player.Input{buttons: c["buttons"]}, c["yaw"])

  check.(intent, c["intent"], c)
end

for c <- cases["rates"] do
  facts =
    Map.new(Map.from_struct(%RelativeMotion{}), fn {key, _} -> {key, c[Atom.to_string(key)]} end)

  for kind <- [:air, :water, :lava] do
    {:ok, actual} = RelativeMotion.speed(kind, struct!(RelativeMotion, facts))

    unless bits.(actual) == bits.(c[Atom.to_string(kind)]),
      do: raise("Native relative rate mismatch #{kind} #{inspect(c)} #{actual}")
  end
end

IO.puts(
  "PASS: #{length(cases["vectors"])} native vectors/accelerations, #{length(cases["intents"])} server intents and #{length(cases["rates"])} air/water/lava rates."
)
