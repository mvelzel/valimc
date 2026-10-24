# Combat packets (VMC-037n): ValiMC's damage events with a cause and direct
# entity, attack and shield sounds, the sweep and damage indicator particles
# and the critical hit animations are vanilla's bytes (`CombatOracle packets`).
alias Valimc.Protocol.{CombatPackets, EntityPackets, Packets, Wire}
[path] = System.argv()
cases = path |> File.read!() |> JSON.decode!()

encode = fn {id, body} ->
  IO.iodata_to_binary([Wire.varint(id), body]) |> Base.encode16(case: :lower)
end

ours =
  Map.new(cases, fn {name, _} ->
    packet =
      case String.split(name, "_") do
        ["damage", "explosion", "5", "none", "position"] ->
          Packets.damage_event(5, :explosion, nil, nil, {1.5, -60.25, -1000.125})

        ["damage" | rest] ->
          [entity, cause, direct] = rest |> Enum.take(-3) |> Enum.map(&String.to_integer/1)
          type = rest |> Enum.drop(-3) |> Enum.join("_") |> String.to_atom()
          Packets.damage_event(entity, type, cause, direct)

        # Sounds are encoded below, with the oracle's seeds.
        ["sound" | _] ->
          nil

        ["particles", "sweep"] ->
          CombatPackets.particles(
            "minecraft:sweep_attack",
            {10.25, 64.9, -3.5},
            {-0.5, 0.0, 0.866},
            0.0,
            0
          )

        ["particles", "damage"] ->
          CombatPackets.particles(
            "minecraft:damage_indicator",
            {-7.5, 65.0, 2.25},
            {0.1, 0.0, 0.1},
            0.2,
            3
          )

        ["animate", action] ->
          EntityPackets.animate(42, String.to_integer(action))
      end

    {name, packet}
  end)

# Sounds take the oracle's seed sequence, in its order.
sounds =
  for sound <-
        ("priv/registry/combat_facts.json" |> File.read!() |> JSON.decode!())["packet_sounds"],
      source <- ~w(player hostile),
      do: {sound, source}

{_, seeded} =
  Enum.reduce(sounds, {0x123456789ABCDEF, %{}}, fn {sound, source}, {seed, acc} ->
    <<signed::signed-64>> = <<seed::64>>

    packet =
      CombatPackets.sound(sound, source, {-12.3, 70.0, 4.9}, 1.0, 0.8999999761581421, signed)

    {rem(seed * 31 + 7, 0x10000000000000000), Map.put(acc, "sound_#{sound}_#{source}", packet)}
  end)

failures =
  for {name, wire} <- cases,
      packet = Map.get(seeded, name, ours[name]),
      encode.(packet) != wire,
      do: {name, wire, encode.(packet)}

if failures != [] do
  for f <- Enum.take(failures, 5), do: IO.puts("FAIL #{inspect(f)}")
  System.halt(1)
end

IO.puts("PASS: #{map_size(cases)} combat packets equal vanilla's bytes")
