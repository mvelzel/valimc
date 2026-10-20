# VMC-023d: ValiMC's overworld chunk biomes equal vanilla's (BiomeOracle).
# ValiMC fills every full chunk of the seed-20261020 vanilla world, then the
# scattered reference chunks, in the oracle's order, carrying lookup history
# from chunk to chunk as one vanilla thread does. Its climate targets and
# biomes must equal vanilla's single-thread reference exactly. Against the
# biomes the world stored, which vanilla's worker threads filled with other
# lookup histories, every difference must be a tie: both biomes at the minimal
# climate distance.
[path] = System.argv()
facts = path |> File.read!() |> JSON.decode!()
palette = List.to_tuple(facts["biomes"])
chunks = facts["chunks"]
preset = "minecraft:overworld"

{:ok, state} = Valimc.Worldgen.new(20_261_020, "minecraft:overworld")

{:ok, {names, results}} =
  Valimc.Native.worldgen_chunk_biomes(state, preset, Enum.map(chunks, &{&1["x"], &1["z"]}))

names = List.to_tuple(names)

from_hex = fn hex ->
  for <<byte::binary-2 <- hex>>, do: elem(palette, String.to_integer(byte, 16))
end

# Storage index (y, z, x within a section) to lookup index (x, y, z).
lookup_index = fn k ->
  {s, r} = {div(k, 64), rem(k, 64)}
  {y, z, x} = {div(r, 16), rem(div(r, 4), 4), rem(r, 4)}
  s * 64 + x * 16 + y * 4 + z
end

{equal, ties} =
  Enum.zip(chunks, results)
  |> Enum.reduce({0, 0}, fn {chunk, {biomes, targets}}, {equal, ties} ->
    where = "chunk #{chunk["x"]},#{chunk["z"]}"
    ours = for <<i <- biomes>>, do: elem(names, i)

    unless :crypto.hash(:sha256, targets) |> Base.encode16(case: :lower) == chunk["targets"],
      do: raise("#{where}: climate targets differ from vanilla's")

    unless ours == from_hex.(chunk["reference"]),
      do: raise("#{where}: biomes differ from vanilla's single-thread reference")

    world = if chunk["world"], do: from_hex.(chunk["world"]), else: ours

    chunk_ties =
      for {{mine, stored}, k} <- Enum.with_index(Enum.zip(ours, world)), mine != stored do
        offset = lookup_index.(k) * 48

        <<t::signed-64, h::signed-64, c::signed-64, e::signed-64, d::signed-64, w::signed-64>> =
          binary_part(targets, offset, 48)

        {:ok, closest} = Valimc.Native.worldgen_closest_biomes(state, preset, [t, h, c, e, d, w])

        unless mine in closest and stored in closest,
          do:
            raise(
              "#{where} quart #{k}: stored #{stored}, ValiMC #{mine}; closest are #{inspect(closest)}"
            )

        k
      end

    if chunk["world"],
      do: {equal + length(ours) - length(chunk_ties), ties + length(chunk_ties)},
      else: {equal, ties}
  end)

stored = Enum.count(chunks, & &1["world"])

IO.puts(
  "PASS: #{length(chunks)} chunks (#{stored} stored, #{length(chunks) - stored} scattered): climate " <>
    "targets and biomes equal vanilla's single-thread reference (#{tuple_size(palette)} biomes); of " <>
    "#{equal + ties} stored quarts #{equal} equal the world, #{ties} differ only where biomes tie on climate"
)
