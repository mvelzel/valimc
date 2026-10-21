# VMC-022b: ValiMC's computed sky and block light equal what vanilla's own
# `LevelLightEngine` computes (LightOracle) in every cell of every full chunk of a
# vanilla world whose eight neighbours are full (light travels at most 15 blocks,
# so those decide it).
alias Valimc.Anvil.{Chunk, RegionFile}
alias Valimc.{NBT, Native}

[facts_path, light_path, light_bin] = System.argv()
Valimc.Registry.BlockFacts.install!()
facts = facts_path |> File.read!() |> JSON.decode!()

images =
  for row <- facts["chunks"], row["sections"] != nil do
    bytes = File.read!(row["path"])
    {:ok, region} = RegionFile.coords(row["path"])
    slot = Enum.find(RegionFile.slots(bytes), &(elem(&1, 0) == row["index"]))
    {:ok, nbt} = RegionFile.chunk(bytes, slot, {Path.dirname(row["path"]), region})
    {:ok, tag} = NBT.read(nbt)
    {{:ok, %{chunk: {cx, cz}, sections: specs}}, _} = Chunk.column(tag)
    {:ok, image} = Native.column_image_of(specs)
    {cx, cz, image}
  end

{xs, zs} = images |> Enum.map(fn {x, z, _} -> {x, z} end) |> Enum.unzip()
{min_x, min_z} = {Enum.min(xs), Enum.min(zs)}

{:ok, lit} =
  Native.light_columns(images, min_x, min_z, Enum.max(xs) - min_x + 1, Enum.max(zs) - min_z + 1)

ours = Map.new(lit, fn {x, z, light} -> {{x, z}, light} end)
vanilla = File.read!(light_bin)
listed = (light_path |> File.read!() |> JSON.decode!())["chunks"]
chunk_bytes = 24 * 4096

nibble = fn layer, i ->
  byte = :binary.at(layer, div(i, 2))
  if rem(i, 2) == 0, do: Bitwise.band(byte, 15), else: Bitwise.bsr(byte, 4)
end

mismatches =
  for {%{"x" => cx, "z" => cz}, n} <- Enum.with_index(listed),
      theirs = binary_part(vanilla, n * chunk_bytes, chunk_bytes),
      mine = ours[{cx, cz}],
      mine != theirs,
      s <- 0..23,
      {kind, offset} <- [sky: s * 4096, block: s * 4096 + 2048],
      a = binary_part(mine, offset, 2048),
      b = binary_part(theirs, offset, 2048),
      a != b,
      i <- 0..4095,
      nibble.(a, i) != nibble.(b, i),
      do:
        {kind,
         {cx * 16 + Bitwise.band(i, 15), (s - 4) * 16 + Bitwise.bsr(i, 8),
          cz * 16 + Bitwise.band(Bitwise.bsr(i, 4), 15)}, nibble.(a, i), nibble.(b, i)}

if mismatches != [] do
  raise "light differs from vanilla's engine in #{length(mismatches)} cells " <>
          "#{inspect(Enum.frequencies_by(mismatches, &elem(&1, 0)))} over #{length(listed)} chunks; " <>
          "e.g. (kind, position, ValiMC, vanilla): #{inspect(Enum.take(Enum.sort(mismatches), 12))}"
end

IO.puts(
  "PASS: computed sky and block light equal vanilla's light engine in every cell of " <>
    "#{length(listed)} chunks with full neighbours (#{length(listed) * 24 * 4096 * 2} values)"
)
