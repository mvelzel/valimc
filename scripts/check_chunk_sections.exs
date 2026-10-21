# VMC-021b: every overworld chunk of a vanilla world imports into ValiMC section
# storage with vanilla's status decision and, for full chunks, exactly the block
# states and biomes vanilla loads (per-section digests from ChunkOracle). The
# chunk packet sections ValiMC encodes for them are written for
# `ChunkOracle verify`, which decodes them with vanilla's network reader.
alias Valimc.Anvil.{Chunk, RegionFile}
alias Valimc.NBT
alias Valimc.Protocol.Data
alias Valimc.World.Blocks

[facts_path, out_dir] = System.argv()
File.mkdir_p!(out_dir)
Blocks.init!()
facts = facts_path |> File.read!() |> JSON.decode!()
names = Data.registries()["minecraft:worldgen/biome"] |> List.to_tuple()

digest = fn states, biomes, s ->
  biome_text = for <<id::16 <- binary_part(biomes, s * 128, 128)>>, do: [elem(names, id), "\n"]

  :crypto.hash(:sha256, [binary_part(states, s * 8192, 8192), biome_text])
  |> Base.encode16(case: :lower)
end

{counts, _, _, _} =
  facts["chunks"]
  |> Enum.with_index()
  |> Enum.reduce({%{full: 0, skipped: 0}, %{}, %{}, %{}}, fn {row, i},
                                                             {counts, files, regions, cache} ->
    path = row["path"]
    files = Map.put_new_lazy(files, path, fn -> File.read!(path) end)
    bytes = files[path]
    {:ok, region} = RegionFile.coords(path)
    slot = Enum.find(RegionFile.slots(bytes), &(elem(&1, 0) == row["index"]))
    {:ok, nbt} = RegionFile.chunk(bytes, slot, {Path.dirname(path), region})
    {:ok, tag} = NBT.read(nbt)
    {result, cache} = Chunk.column(tag, cache)

    case {result, row["sections"]} do
      {{:skip, status}, nil} ->
        unless status == row["status"],
          do: raise("chunk #{i}: status #{status}, vanilla #{row["status"]}")

        {%{counts | skipped: counts.skipped + 1}, files, regions, cache}

      {{:ok, %{chunk: chunk, sections: specs}}, digests} when is_list(digests) ->
        unless chunk == {row["x"], row["z"]}, do: raise("chunk #{i}: position #{inspect(chunk)}")
        key = Valimc.World.region_key(chunk)
        regions = Map.put_new_lazy(regions, key, fn -> elem(Blocks.new(key), 1) end)
        blocks = regions[key]
        :ok = Valimc.Native.put_column(blocks.ref, elem(chunk, 0), elem(chunk, 1), specs)
        {:ok, states, biomes} = Blocks.dump_column(blocks, chunk)

        for {expected, s} <- Enum.with_index(digests),
            digest.(states, biomes, s) != expected,
            do: raise("chunk #{inspect(chunk)} section #{s - 4} differs from vanilla's load")

        %{sections: sections} = Blocks.encode(blocks, chunk)
        File.write!(Path.join(out_dir, "chunk-#{i}.bin"), sections)
        {%{counts | full: counts.full + 1}, files, regions, cache}

      other ->
        raise "chunk #{i} (#{row["status"]}): #{inspect(elem(other, 0))}"
    end
  end)

# The whole import path: Valimc.Anvil.Import writes region logs, which load back
# (as an owner loads them) to the same sections.
world =
  facts["chunks"] |> hd() |> Map.fetch!("path") |> Path.join("../../../../..") |> Path.expand()

imported = Path.join(out_dir, "imported-world")
{:ok, report} = Valimc.Anvil.Import.run(world, imported)

unless report.chunks == counts.full and report.error_count == 0,
  do: raise("import report differs: #{inspect(report)}")

loaded =
  for %{"sections" => expected, "x" => x, "z" => z} <- facts["chunks"], reduce: %{} do
    loaded ->
      chunk = {x, z}
      key = Valimc.World.region_key(chunk)

      loaded =
        Map.put_new_lazy(loaded, key, fn ->
          images = Valimc.World.Store.durable(imported, key, :columns)
          {:ok, blocks} = Blocks.new(key, %{}, images)
          blocks
        end)

      {:ok, states, biomes} = Blocks.dump_column(loaded[key], chunk)

      for {digest_expected, s} <- Enum.with_index(expected),
          digest.(states, biomes, s) != digest_expected,
          do: raise("imported chunk #{inspect(chunk)} section #{s - 4} differs after reloading")

      loaded
  end

IO.puts(
  "PASS: #{counts.full} full vanilla chunks import with vanilla's blocks and biomes in every section; " <>
    "#{counts.skipped} chunks of other statuses are skipped as vanilla's status says; " <>
    "Valimc.Anvil.Import wrote #{map_size(loaded)} region logs that reload to the same sections"
)
