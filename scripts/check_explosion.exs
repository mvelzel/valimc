# VMC-050a: the physics kernel's explosion reach and exposure, and the
# default calculator's damage, against vanilla's over supplied scenes.
alias Valimc.Physics.Kernel
alias Valimc.Living.Explosions
alias Valimc.Data.Float32
Valimc.Data.BlockFacts.install!()

[file] = System.argv()
raw = file |> File.read!() |> JSON.decode!()

true =
  raw["version"] == "26.3" and raw["server_sha1"] == "33680f5f2ac32864d6d7cf5e56a705fdb3e05f4c"

scenes =
  Map.new(raw["scenes"], fn {name, %{"min" => [x0, y0, z0], "size" => size, "states" => hex}} ->
    states = for <<state::16 <- Base.decode16!(hex, case: :lower)>>, do: state

    cells =
      for z <- 0..(size - 1), y <- 0..(size - 1), x <- 0..(size - 1), do: {x0 + x, y0 + y, z0 + z}

    {name, Valimc.World.View.of(Map.new(Enum.zip(cells, states)))}
  end)

for c <- raw["craters"] do
  {:ok, {cells, false}} =
    Kernel.explosion(
      scenes[c["scene"]],
      List.to_tuple(c["center"]),
      c["radius"],
      c["seed"],
      -64,
      384
    )

  cells = Enum.map(cells, &elem(&1, 0))
  expected = Enum.map(c["cells"], &List.to_tuple/1)

  unless cells == expected do
    raise "crater #{c["scene"]} r#{c["radius"]} seed #{c["seed"]}: #{length(cells)} cells, " <>
            "vanilla #{length(expected)}; missing #{inspect(Enum.take(expected -- cells, 5))}, " <>
            "extra #{inspect(Enum.take(cells -- expected, 5))}"
  end
end

for c <- raw["exposures"] do
  center = List.to_tuple(c["center"])
  {:ok, [seen]} = Kernel.exposure(scenes[c["scene"]], center, [List.to_tuple(c["box"])])
  damage = Explosions.damage(c["radius"], center, List.to_tuple(c["position"]), seen)

  # Vanilla's floats print in their shortest form.
  unless seen == Float32.round(c["seen"]) and damage == Float32.round(c["damage"]) do
    raise "exposure #{inspect(c["position"])} #{inspect(c["box"])}: #{seen} / #{damage}, " <>
            "vanilla #{c["seen"]} / #{c["damage"]}"
  end
end

IO.puts(
  "PASS: #{length(raw["craters"])} explosion craters and #{length(raw["exposures"])} " <>
    "exposure and damage cases equal vanilla's"
)

# The explode packet, byte for byte (`ExplosionOracle packet`).
packets = "priv/protocol/explosion_packet.json" |> File.read!() |> JSON.decode!()

for c <- packets["cases"] do
  knockback = if k = c["knockback"], do: List.to_tuple(k)

  {id, payload} =
    Valimc.Protocol.ExplodePacket.packet(
      List.to_tuple(c["center"]),
      c["radius"],
      c["count"],
      knockback,
      c["radius"] < 2.0
    )

  wire = IO.iodata_to_binary([Valimc.Protocol.Wire.varint(id), payload])

  unless Base.encode16(wire, case: :lower) == c["wire"],
    do: raise("Explode packet differs: #{inspect(c)}")
end

IO.puts("PASS: #{length(packets["cases"])} explode packets equal vanilla's bytes")
