# Native mobs' effects (VMC-037p) against vanilla's: each script of
# `addEffect`, `removeEffect`, `removeAllEffects`, `setHealth` and effect
# ticks on a fresh mob gives the same effects, health, maximum, absorption
# and movement speed after every operation.
Valimc.Entity.MobFacts.install!()
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

op = fn
  [0, id, ticks, amplifier, flags] ->
    {:add, id,
     {ticks, amplifier, Bitwise.band(flags, 1) != 0, Bitwise.band(flags, 2) != 0,
      Bitwise.band(flags, 4) != 0}}

  [1, id] ->
    {:remove, id}

  [2] ->
    {:clear}

  [3, health] ->
    {:health, health * 1.0}

  [4, count] ->
    {:tick, count}
end

for c <- cases do
  native = Valimc.Native.mob_effect_parity(c["type"], Enum.map(c["ops"], op))

  for {{state, expected}, at} <- Enum.zip(native, c["states"]) |> Enum.with_index() do
    {changed, effects, health, maximum, absorption, speed} = state

    effects =
      for {id, rungs} <- effects, do: [id, Enum.map(rungs, &Tuple.to_list/1)]

    actual = %{
      "changed" => changed,
      "effects" => effects,
      "health" => health,
      "maximum" => maximum,
      "absorption" => absorption,
      "speed" => speed
    }

    unless actual == expected,
      do:
        raise(
          "#{c["type"]} #{c["script"]} op #{at} #{inspect(Enum.at(c["ops"], at))}: " <>
            "native #{inspect(actual)}, vanilla #{inspect(expected)}"
        )
  end
end

IO.puts(
  "PASS: #{length(cases)} effect scripts on fresh native mobs equal vanilla after every operation."
)
